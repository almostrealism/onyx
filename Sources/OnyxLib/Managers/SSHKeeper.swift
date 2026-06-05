//
// SSHKeeper.swift
//
// Responsibility: Maintain TWO warm SSH mux masters per host at all
//                 times — a primary and a spare. If the primary dies,
//                 the keeper immediately fails over to the spare and
//                 spawns a new replacement on the dead slot in the
//                 background. Net effect: the application never sees
//                 a stretch longer than one tick (2s) where no live
//                 mux is available.
// Scope: Shared singleton (SSHKeeper.shared).
// Threading: Tick fires on main; per-host health checks and master
//            establishment happen on a concurrent userInitiated queue.
//            All state mutation is lock-guarded.
//
// Why this exists:
//   The whole point of Onyx is a durable SSH connection. A single
//   mux master is a single point of failure — sleep/wake, network
//   change, server restart, even an OS-level socket cleanup, and
//   suddenly no mux. Doubling them up gives us a hot spare that's
//   instantly promotable. We're willing to spend a full CPU core or
//   more on this. Connection durability is the top priority.
//
// Console filter for trace:
//   subsystem:com.onyx category:ssh
//

import Foundation
import Darwin

public final class SSHKeeper {

    public static let shared = SSHKeeper()

    /// Health-check cadence. 2s detects dead sockets nearly immediately
    /// while leaving headroom for the actual `ssh -O check` (2s timeout).
    public static let tickInterval: TimeInterval = 2

    /// Smoke-test cadence — periodically run an actual `true` command
    /// through each slot's mux to catch the "socket is fine but the
    /// underlying TCP died silently" failure mode that `ssh -O check`
    /// cannot detect. Previously 30s, which left a long window where
    /// the status line could show "alive" while connections were
    /// actually dead. 4s is fast enough that the cached state usually
    /// matches reality within one UI refresh cycle.
    public static let smokeTestInterval: TimeInterval = 4

    /// Rotation cadence — pre-emptively recycle each slot's master on
    /// this period so we never accumulate long-running connection state
    /// that an OS, sshd, or network device might decide to clean up.
    /// 30 min per slot ⇒ no master older than ~30 min at any time.
    public static let rotationInterval: TimeInterval = 1800

    /// Aggressive ServerAlive — fail a silent TCP connection in ≈25s.
    public static let serverAliveInterval = 10
    public static let serverAliveCountMax = 3
    public static let connectTimeout = 15
    /// Master persists for 10 min after last client; we poll every 2s
    /// so it never goes idle that long, but if everything else dies
    /// the master itself doesn't expire underneath us.
    public static let controlPersist = 600

    /// One slot of the redundant pair.
    public struct SlotState: Equatable {
        public let slot: Int            // 0 (A) or 1 (B)
        public let path: String         // ControlPath on disk
        public var alive: Bool = false
        public var establishing: Bool = false
        public var consecutiveFailures: Int = 0
        public var establishedAt: Date? = nil
        /// When we last successfully smoke-tested an actual command
        /// through this slot. `nil` means "never" — fires on next tick.
        public var lastSmokeTestAt: Date? = nil
        /// Set when `ssh -O check` says the slot is alive but a smoke
        /// test (real command through the mux) failed. Indicates a
        /// silently-broken connection that the cheap check missed.
        public var lastSmokeTestFailed: Bool = false
        /// PID of the master process that owns this slot's socket.
        /// Captured right after establish via lsof, used by killMaster
        /// to terminate the master directly even after the socket file
        /// has been removed from disk. Without this, masters stuck in
        /// uninterruptible kernel sleeps (D state with pending TCP I/O)
        /// got orphaned because lsof can't find them by path once the
        /// socket file is gone.
        public var masterPID: pid_t? = nil
    }

    /// One host's pair of slots + which one is currently primary.
    public struct HostState: Equatable {
        public var slots: [SlotState]
        public var primarySlot: Int     // 0 or 1
        /// Last time we rotated this host's slots — used to schedule
        /// the next pre-emptive rotation.
        public var lastRotationAt: Date? = nil

        public var primary: SlotState { slots[primarySlot] }
        public var spare: SlotState { slots[1 - primarySlot] }
    }

    private var hostStates: [UUID: HostState] = [:]
    private let lock = NSLock()
    /// Strong ref — keeper outlives any single AppState. The original
    /// weak ref let the keeper silently stop when a window closed.
    private var appState: AppState?
    private var timer: Timer?
    /// Per-host serial queue. Eliminates the dispatch-thread pile-up that
    /// the concurrent queue caused — each host gets exactly one worker
    /// thread, and a stuck SSH call only stalls that one host.
    private var hostQueues: [UUID: DispatchQueue] = [:]
    /// Hosts that already have a maintenance task enqueued. We never let
    /// a second one pile in until the first dequeues — that's how we
    /// killed the dispatch pool last time.
    private var enqueued: Set<UUID> = []
    /// Kill switch. When true, tick() does nothing. Toggled from the
    /// monitor overlay's mux diagnostic panel.
    public private(set) var enabled: Bool = true

    private init() {}

    private func hostQueue(for hostID: UUID) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = hostQueues[hostID] { return q }
        let q = DispatchQueue(label: "com.onyx.ssh-keeper.host.\(hostID.uuidString.prefix(8))",
                              qos: .userInitiated)
        hostQueues[hostID] = q
        return q
    }

    // MARK: - Lifecycle

    /// Start the supervisor. Idempotent — second calls while running
    /// are no-ops. No-op under XCTest so unit tests don't spawn ssh.
    public func start(appState: AppState) {
        if NSClassFromString("XCTest") != nil { return }
        guard timer == nil else { return }
        self.appState = appState
        OnyxLog.ssh.info("SSHKeeper starting (tick=\(Self.tickInterval, privacy: .public)s)")

        DispatchQueue.main.async { [weak self] in self?.tick() }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        OnyxLog.ssh.info("SSHKeeper stopped")
    }

    /// Shutdown — close every slot for every host, definitively.
    /// Called from `applicationWillTerminate` so a force-quit no longer
    /// leaves orphan master processes holding remote TCP connections
    /// open. Idempotent and bounded.
    public func shutdown() {
        OnyxLog.ssh.notice("SSHKeeper shutdown — closing all masters")
        setEnabled(false)
        timer?.invalidate()
        timer = nil

        // Snapshot the host list under the lock, then close masters
        // outside the lock so we don't hold it during ssh -O exit calls.
        lock.lock()
        let entries = hostStates.compactMap { (id, state) -> (UUID, String, [(String, pid_t?)])? in
            let slotInfo = state.slots.map { ($0.path, $0.masterPID) }
            guard let host = appState?.hosts.first(where: { $0.id == id }) else {
                return (id, "", slotInfo)
            }
            return (id, Self.userHost(for: host), slotInfo)
        }
        hostStates.removeAll()
        lock.unlock()

        for (_, userHost, slotInfo) in entries {
            for (path, pid) in slotInfo {
                Self.stopMaster(at: path, userHost: userHost, knownPID: pid)
            }
        }
        OnyxLog.ssh.notice("SSHKeeper shutdown complete")
    }

    /// Nuclear cleanup — kill every ssh master process the keeper has
    /// ever spawned (or that anyone else has spawned with a ControlPath
    /// in our mux dir), reset all in-memory state, sweep socket files.
    /// Equivalent to running `scripts/ssh-leak-cleanup.sh` but from
    /// inside the app. Returns (killed, refused) — `refused` are
    /// processes stuck in uninterruptible kernel sleep that even
    /// SIGKILL can't reach immediately; those generally die on their
    /// own when the underlying TCP times out.
    @discardableResult
    public func reapAll() -> (killed: Int, refused: Int) {
        OnyxLog.ssh.notice("SSHKeeper reapAll: nuclear cleanup requested")

        // Snapshot every known PID across every host so the targeted
        // kills run before the directory-wide sweep (preferring our
        // precise tracking over a process-table scan).
        lock.lock()
        var knownPIDs: [(pid_t, String?)] = []
        for state in hostStates.values {
            for slot in state.slots {
                if let pid = slot.masterPID {
                    knownPIDs.append((pid, nil))
                }
            }
        }
        hostStates.removeAll()
        lock.unlock()

        for (pid, _) in knownPIDs {
            _ = SSHProcess.killAndVerify(pid: pid)
        }

        let muxDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux").path
        let result = SSHProcess.reapAllInDir(muxDir)
        OnyxLog.ssh.notice("""
            reapAll done: killed=\(result.killed, privacy: .public) \
            refused=\(result.refused, privacy: .public)
            """)
        return result
    }

    /// Dump a human-readable inventory of every ssh process and every
    /// mux socket the keeper can see. Logs it under
    /// subsystem:com.onyx category:ssh AND returns it for the UI to
    /// display. Use when "why are there so many connections?" needs
    /// ground truth instead of cached state.
    public func inventoryDump() -> String {
        let muxDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux").path
        var dump = SSHProcess.inventoryDump(muxDir: muxDir)

        lock.lock()
        dump += "\n\n=== Keeper state ===\n"
        if hostStates.isEmpty {
            dump += "  (no host state tracked)\n"
        }
        for (hid, state) in hostStates {
            dump += "  host \(hid.uuidString.prefix(8)) primary=slot\(state.primarySlot)\n"
            for slot in state.slots {
                let pidStr = slot.masterPID.map { "pid \($0)" } ?? "no pid"
                let aliveStr = slot.alive ? "alive" : (slot.establishing ? "establishing" : "DEAD")
                dump += "    slot\(slot.slot) \(aliveStr) \(pidStr)\n"
                dump += "      path=\(slot.path)\n"
            }
        }
        lock.unlock()

        OnyxLog.ssh.notice("inventoryDump:\n\(dump, privacy: .public)")
        return dump
    }

    /// Emergency kill switch — disables all supervisor work. Existing
    /// state stays so the UI keeps reporting the last-known status, but
    /// no new ssh calls are made and no new maintenance tasks enqueue.
    /// Toggled by the user from the diagnostic panel when the keeper
    /// itself is misbehaving.
    public func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
        OnyxLog.ssh.notice("SSHKeeper \(value ? "ENABLED" : "DISABLED", privacy: .public)")
    }

    // MARK: - Public API for AppState

    /// Path of the currently-active (primary) slot for a host. Always
    /// returns SOMETHING — if the keeper hasn't observed this host yet,
    /// returns slot A's default path (which matches the legacy single-
    /// slot path so existing utility code Just Works).
    public func controlPath(for host: HostConfig) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let state = hostStates[host.id] {
            return state.primary.path
        }
        return Self.defaultSlotPath(for: host.id, slot: 0)
    }

    /// Cached liveness — synchronous, no SSH call required. Updated by
    /// the background tick loop on every cycle.
    public func isMuxAlive(for host: HostConfig) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hostStates[host.id]?.primary.alive ?? false
    }

    /// Snapshot of a host's full slot state — used by the diagnostic
    /// view so the user can see what the supervisor has been doing.
    public func state(for host: HostConfig) -> HostState? {
        lock.lock()
        defer { lock.unlock() }
        return hostStates[host.id]
    }

    /// Forced reset — tear down both slots and let the next tick
    /// re-establish from scratch. Called from the diagnostic UI when
    /// the user clicks "Reset mux".
    public func reset(for host: HostConfig) {
        OnyxLog.ssh.notice("SSHKeeper reset: host=\(host.label, privacy: .public)")
        lock.lock()
        let knownPIDs = (hostStates[host.id]?.slots.map(\.masterPID)) ?? [nil, nil]
        hostStates.removeValue(forKey: host.id)
        lock.unlock()

        let userHost = Self.userHost(for: host)
        for slot in 0...1 {
            let path = Self.defaultSlotPath(for: host.id, slot: slot)
            let pid = slot < knownPIDs.count ? knownPIDs[slot] : nil
            Self.stopMaster(at: path, userHost: userHost, knownPID: pid)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Tick

    private func tick() {
        // No longer stops the supervisor when appState is briefly nil;
        // we just skip this tick. The previous behavior silently killed
        // the supervisor when any window closed.
        guard enabled, let appState = appState else { return }
        let hosts = appState.hosts.filter { !$0.isLocal }
        for host in hosts {
            // Skip if this host's maintenance is already enqueued or
            // running. Without this guard, every tick piled work onto a
            // concurrent queue, exhausting the dispatch thread pool when
            // SSH calls hung. The hang trace showed 64+ stuck worker
            // threads — exactly the dispatch pool soft limit.
            lock.lock()
            if enqueued.contains(host.id) {
                lock.unlock()
                continue
            }
            enqueued.insert(host.id)
            lock.unlock()

            hostQueue(for: host.id).async { [weak self] in
                self?.maintain(host: host)
                self?.lock.lock()
                self?.enqueued.remove(host.id)
                self?.lock.unlock()
            }
        }

        // Orphan reaper. Runs on its own concurrent queue so a slow
        // ps/lsof can't starve per-host maintenance. Deduplicated the
        // same way as host maintenance.
        lock.lock()
        let reapInFlight = orphanReapInFlight
        if !reapInFlight { orphanReapInFlight = true }
        lock.unlock()
        if !reapInFlight {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.reapOrphanMasters()
                self?.lock.lock()
                self?.orphanReapInFlight = false
                self?.lock.unlock()
            }
        }
    }

    private var orphanReapInFlight = false

    /// Walk every `ssh` process on the box that has a `ControlPath`
    /// argument pointing somewhere under `~/.ssh/onyx-mux/`. Any PID
    /// whose path isn't in our current slot set gets SIGKILLed. This
    /// is what catches masters that survived past their re-establish
    /// because killMaster couldn't find them (the socket file was
    /// already gone — lsof returned nothing — so the previous reap
    /// missed them and they kept holding remote TCP connections open).
    /// Those are the "tons of connections" the user kept seeing pile
    /// up before quitting + running the cleanup script.
    private func reapOrphanMasters() {
        // Build the set of paths we currently expect.
        lock.lock()
        var current = Set<String>()
        for state in hostStates.values {
            for slot in state.slots { current.insert(slot.path) }
        }
        lock.unlock()

        let muxDirPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux")
            .path

        let processes = SSHProcess.findAllSSHMastersInDir(muxDirPrefix)
        var reaped = 0
        for (pid, path) in processes {
            if current.contains(path) { continue }
            let died = SSHProcess.killAndVerify(pid: pid)
            if died { reaped += 1 } else {
                OnyxLog.ssh.error("""
                    orphan reap: pid \(pid, privacy: .public) refused SIGKILL — \
                    probably stuck in kernel D state; will retry next cycle
                    """)
            }
        }
        if reaped > 0 {
            OnyxLog.ssh.notice("""
                orphan reap: killed \(reaped, privacy: .public) leaked master(s) \
                from a previous re-establish cycle
                """)
        }
    }

    /// Per-host maintenance — runs concurrently for every host on
    /// every tick. Checks both slots, promotes the spare if the primary
    /// died, and spawns a replacement master for any dead slot.
    private func maintain(host: HostConfig) {
        // Initialize state on first sight.
        lock.lock()
        if hostStates[host.id] == nil {
            hostStates[host.id] = HostState(
                slots: [
                    SlotState(slot: 0, path: Self.defaultSlotPath(for: host.id, slot: 0)),
                    SlotState(slot: 1, path: Self.defaultSlotPath(for: host.id, slot: 1))
                ],
                primarySlot: 0
            )
        }
        var state = hostStates[host.id]!
        lock.unlock()

        let userHost = Self.userHost(for: host)
        let now = Date()

        // 1. Cheap socket-level health check on each slot.
        for i in 0..<state.slots.count {
            let alive = Self.checkAlive(path: state.slots[i].path,
                                        userHost: userHost)
            let wasAlive = state.slots[i].alive
            state.slots[i].alive = alive
            if alive {
                state.slots[i].consecutiveFailures = 0
                if !wasAlive {
                    OnyxLog.ssh.info("""
                        slot \(i, privacy: .public) revived: host=\(host.label, privacy: .public)
                        """)
                }
            } else {
                state.slots[i].consecutiveFailures += 1
                if wasAlive {
                    OnyxLog.ssh.notice("""
                        slot \(i, privacy: .public) died: host=\(host.label, privacy: .public)
                        """)
                }
            }
        }

        // 2. Smoke test — for any slot that passed the cheap check, run
        //    an actual `true` through it every `smokeTestInterval`s to
        //    catch silently-broken TCP that the IPC check can't see.
        for i in 0..<state.slots.count where state.slots[i].alive {
            let last = state.slots[i].lastSmokeTestAt ?? .distantPast
            guard now.timeIntervalSince(last) >= Self.smokeTestInterval else { continue }
            state.slots[i].lastSmokeTestAt = now
            let smokeOk = Self.smokeTest(path: state.slots[i].path,
                                         userHost: userHost)
            state.slots[i].lastSmokeTestFailed = !smokeOk
            if !smokeOk {
                OnyxLog.ssh.notice("""
                    smoke test FAILED: host=\(host.label, privacy: .public) \
                    slot=\(i, privacy: .public) — socket alive but command timed out, \
                    flagging dead so it gets re-established
                    """)
                state.slots[i].alive = false
            }
        }

        // 3. Promote the spare if primary is dead and spare is alive.
        if !state.slots[state.primarySlot].alive,
           state.slots[1 - state.primarySlot].alive {
            let old = state.primarySlot
            state.primarySlot = 1 - state.primarySlot
            OnyxLog.ssh.notice("""
                MUX FAILOVER: host=\(host.label, privacy: .public) \
                slot \(old, privacy: .public) → slot \(state.primarySlot, privacy: .public)
                """)
        }

        // 4. Pre-emptive rotation. When both slots are alive and the
        //    rotation period has elapsed, swap primary/spare and tear
        //    down the new spare (= old primary). The next pass through
        //    the establish step will rebuild it fresh. Net effect: no
        //    master ever stays alive longer than ~rotationInterval.
        if state.slots[0].alive && state.slots[1].alive {
            let lastRotation = state.lastRotationAt ?? .distantPast
            if now.timeIntervalSince(lastRotation) >= Self.rotationInterval {
                let oldPrimary = state.primarySlot
                state.primarySlot = 1 - state.primarySlot
                state.lastRotationAt = now
                OnyxLog.ssh.notice("""
                    MUX ROTATION: host=\(host.label, privacy: .public) \
                    slot \(oldPrimary, privacy: .public) → slot \(state.primarySlot, privacy: .public) \
                    (recycling old primary for freshness)
                    """)
                // Tear down the old primary (now the spare). It'll be
                // marked dead so step 5 establishes a fresh master.
                let oldPath = state.slots[oldPrimary].path
                let oldPID = state.slots[oldPrimary].masterPID
                Self.stopMaster(at: oldPath,
                                userHost: userHost,
                                knownPID: oldPID)
                try? FileManager.default.removeItem(atPath: oldPath)
                state.slots[oldPrimary].alive = false
                state.slots[oldPrimary].establishedAt = nil
                state.slots[oldPrimary].masterPID = nil
                state.slots[oldPrimary].lastSmokeTestAt = nil
            }
        }

        // Persist the updated state.
        lock.lock()
        hostStates[host.id] = state
        lock.unlock()

        // 5. Spawn replacements for any dead slot that isn't already
        //    mid-establishment. Runs on this same concurrent queue —
        //    other hosts' maintenance isn't blocked.
        for i in 0..<state.slots.count {
            if !state.slots[i].alive && !state.slots[i].establishing {
                establish(host: host, slot: i)
            }
        }
    }

    /// Result of a bounded SSH run. `exit == -1` means the process was
    /// killed (timeout or launch failure); otherwise it's the real exit
    /// status. `stderr` is captured for any caller that wants it.
    private typealias BoundedResult = SSHProcess.RunResult

    /// Thin wrapper over `SSHProcess.run` — the actual implementation
    /// lives in the Services layer so other call sites (AppState's
    /// sshMuxStop, etc.) share the same SIGKILL-escalation discipline.
    private static func runSSH(_ args: [String],
                               softTimeout: TimeInterval,
                               captureStderr: Bool = false) -> BoundedResult {
        SSHProcess.run(args, softTimeout: softTimeout, captureStderr: captureStderr)
    }

    /// Smoke-test a slot's mux by sending `true` through it. Bounded
    /// at 3s — anything longer means the multiplexed stream is hung
    /// even though the socket is alive (silent TCP death).
    private static func smokeTest(path: String, userHost: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let result = runSSH([
            "-o", "ControlPath=\(path)",
            "-o", "BatchMode=yes",
            userHost, "true"
        ], softTimeout: 3)
        return result.exit == 0
    }

    /// Run `ssh -O check`. 2s bound + 1s hard kill = ≤3s wall clock.
    private static func checkAlive(path: String, userHost: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let result = runSSH([
            "-o", "ControlPath=\(path)",
            "-O", "check",
            userHost
        ], softTimeout: 2)
        return result.exit == 0
    }

    /// Spawn a fresh `ssh -M -N -f` master on the given slot, verify it
    /// actually responds, and record the result. Every SSH call here
    /// runs through `runSSH` and is wall-clock bounded — this function
    /// is guaranteed to complete within ≈(connectTimeout + 3s) regardless
    /// of how broken the remote host is.
    private func establish(host: HostConfig, slot: Int) {
        lock.lock()
        guard var state = hostStates[host.id], !state.slots[slot].establishing else {
            lock.unlock()
            return
        }
        state.slots[slot].establishing = true
        let slotPath = state.slots[slot].path
        let oldMasterPID = state.slots[slot].masterPID
        state.slots[slot].masterPID = nil  // forget old PID — we're killing it now
        hostStates[host.id] = state
        lock.unlock()

        // Definitively close any prior master on this slot. Without
        // this, the old master process keeps holding its TCP
        // connection to the remote sshd open even though we've moved
        // on to a fresh socket — that's the leak documented in
        // docs/ssh-connection-leak.md (30+ hour-old notty sessions
        // piling up on the remote, eventually tripping MaxStartups
        // and locking the user out). The captured PID is the most
        // reliable way to kill the master; lsof-by-socket can miss
        // masters whose socket file has already been removed.
        Self.stopMaster(at: slotPath,
                        userHost: Self.userHost(for: host),
                        knownPID: oldMasterPID)

        var args: [String] = [
            "-M", "-N", "-f",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(slotPath)",
            "-o", "ControlPersist=\(Self.controlPersist)",
            "-o", "ServerAliveInterval=\(Self.serverAliveInterval)",
            "-o", "ServerAliveCountMax=\(Self.serverAliveCountMax)",
            "-o", "ConnectTimeout=\(Self.connectTimeout)",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if host.ssh.port != 22 { args += ["-p", "\(host.ssh.port)"] }
        if !host.ssh.identityFile.isEmpty { args += ["-i", host.ssh.identityFile] }
        args.append(Self.userHost(for: host))

        OnyxLog.ssh.notice("""
            establishing mux: host=\(host.label, privacy: .public) \
            slot=\(slot, privacy: .public)
            """)

        let result = Self.runSSH(args,
                                 softTimeout: TimeInterval(Self.connectTimeout + 2),
                                 captureStderr: true)

        // Even if ssh exited 0, the -f fork could have failed silently
        // to create the master. Verify with a real -O check before
        // claiming success.
        var success = result.exit == 0
        var capturedPID: pid_t? = nil
        if success {
            success = Self.checkAlive(path: slotPath,
                                      userHost: Self.userHost(for: host))
            if !success {
                OnyxLog.ssh.error("""
                    establish appeared OK but post-check failed: \
                    host=\(host.label, privacy: .public) slot=\(slot, privacy: .public) — \
                    master forked but socket isn't responding
                    """)
            } else {
                // Capture the master's actual PID NOW, while the socket
                // file is fresh. After SIGKILL+reap or a removeItem
                // call this lookup would return nothing. Without this
                // we couldn't kill a stuck master that had outlived
                // its socket file.
                capturedPID = SSHProcess.findMasterPIDs(socketPath: slotPath).first
            }
        }

        if !success {
            OnyxLog.ssh.error("""
                establish FAILED: host=\(host.label, privacy: .public) \
                slot=\(slot, privacy: .public) \
                exit=\(result.exit, privacy: .public) \
                timedOut=\(result.timedOut, privacy: .public) \
                stderr=\(result.stderr, privacy: .public)
                """)
        } else {
            OnyxLog.ssh.info("""
                mux established: host=\(host.label, privacy: .public) \
                slot=\(slot, privacy: .public)
                """)
        }

        lock.lock()
        if var s = hostStates[host.id] {
            s.slots[slot].establishing = false
            s.slots[slot].alive = success
            if success {
                s.slots[slot].establishedAt = Date()
                s.slots[slot].masterPID = capturedPID
                s.slots[slot].lastSmokeTestAt = nil  // re-test soon
                s.slots[slot].lastSmokeTestFailed = false
            } else {
                s.slots[slot].masterPID = nil
            }
            hostStates[host.id] = s
        }
        lock.unlock()
    }

    /// Wholesale teardown of a slot's master. Prefers the captured
    /// PID over `lsof`-by-socket because the socket file may already
    /// be gone (a previous removeItem call, or the kernel reaping it
    /// after the master crashed). Without the PID fallback, stuck
    /// masters got orphaned every cycle and accumulated as the leaked
    /// connections the user reported piling up on remote hosts.
    private static func stopMaster(at path: String,
                                   userHost: String,
                                   knownPID: pid_t? = nil) {
        // Try clean exit first if the socket is still there.
        if FileManager.default.fileExists(atPath: path) {
            _ = SSHProcess.run([
                "-o", "ControlPath=\(path)",
                "-O", "exit",
                userHost
            ], softTimeout: 2)
        }
        // Direct PID kill if we captured one at establish time.
        if let pid = knownPID, kill(pid, 0) == 0 {
            _ = SSHProcess.killAndVerify(pid: pid)
        }
        // Standard lsof-based cleanup as a backup. This still catches
        // masters where we never captured a PID (legacy state, etc.).
        SSHProcess.killMaster(at: path, userHost: userHost)
    }

    // MARK: - Helpers

    private static func userHost(for host: HostConfig) -> String {
        host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
    }

    /// Per-slot control path under ~/.ssh/onyx-mux/. Slot A's path
    /// matches the legacy single-slot path so existing callers keep
    /// working unchanged.
    public static func defaultSlotPath(for hostID: UUID, slot: Int) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".ssh/onyx-mux")
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let name: String
        switch slot {
        case 0: name = "mux-\(hostID.uuidString)"
        case 1: name = "mux-\(hostID.uuidString)-spare"
        default: name = "mux-\(hostID.uuidString)-slot\(slot)"
        }
        return dir.appendingPathComponent(name).path
    }
}
