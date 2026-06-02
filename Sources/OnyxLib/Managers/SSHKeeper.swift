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

public final class SSHKeeper {

    public static let shared = SSHKeeper()

    /// Health-check cadence. 2s detects dead sockets nearly immediately
    /// while leaving headroom for the actual `ssh -O check` (2s timeout).
    public static let tickInterval: TimeInterval = 2

    /// Smoke-test cadence — periodically run an actual `true` command
    /// through each slot's mux to catch the "socket is fine but the
    /// underlying TCP died silently" failure mode that `ssh -O check`
    /// cannot detect. ServerAliveInterval inside the master would
    /// notice eventually, but smoke testing catches it within 30s.
    public static let smokeTestInterval: TimeInterval = 30

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
    private weak var appState: AppState?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.onyx.ssh-keeper",
                                     qos: .userInitiated,
                                     attributes: .concurrent)

    private init() {}

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
        for slot in 0...1 {
            let path = Self.defaultSlotPath(for: host.id, slot: slot)
            Self.stopMaster(at: path, userHost: Self.userHost(for: host))
            try? FileManager.default.removeItem(atPath: path)
        }
        lock.lock()
        hostStates.removeValue(forKey: host.id)
        lock.unlock()
    }

    // MARK: - Tick

    private func tick() {
        guard let appState = appState else { stop(); return }
        let hosts = appState.hosts.filter { !$0.isLocal }
        for host in hosts {
            queue.async { [weak self] in
                self?.maintain(host: host)
            }
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
                Self.stopMaster(at: oldPath, userHost: userHost)
                try? FileManager.default.removeItem(atPath: oldPath)
                state.slots[oldPrimary].alive = false
                state.slots[oldPrimary].establishedAt = nil
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

    /// Smoke-test a slot's mux by actually sending `true` through it.
    /// Bounded at 3s — anything longer means the multiplexed stream is
    /// hung even though the control socket is alive (silent TCP death).
    /// This is the failure mode `ssh -O check` cannot catch.
    private static func smokeTest(path: String, userHost: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "ControlPath=\(path)",
            "-o", "BatchMode=yes",
            userHost, "true"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 3)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()
            process.waitUntilExit()
            killTimer.cancel()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Run `ssh -O check` for the given control path. 2s kill timer
    /// keeps a hung socket from blocking the maintenance loop.
    private static func checkAlive(path: String, userHost: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(path)", "-O", "check", userHost]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 2)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()
            process.waitUntilExit()
            killTimer.cancel()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Spawn a fresh `ssh -M -N -f` master on the given slot. Logs both
    /// success and the stderr on failure (visible in Console under
    /// subsystem:com.onyx category:ssh).
    private func establish(host: HostConfig, slot: Int) {
        // Mark establishing so concurrent ticks don't double-fire.
        lock.lock()
        guard var state = hostStates[host.id], !state.slots[slot].establishing else {
            lock.unlock()
            return
        }
        state.slots[slot].establishing = true
        let slotPath = state.slots[slot].path
        hostStates[host.id] = state
        lock.unlock()

        // Stale socket may still be on disk — remove it before
        // ControlMaster=yes refuses to overwrite.
        try? FileManager.default.removeItem(atPath: slotPath)

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
        if host.ssh.port != 22 {
            args += ["-p", "\(host.ssh.port)"]
        }
        if !host.ssh.identityFile.isEmpty {
            args += ["-i", host.ssh.identityFile]
        }
        args.append(Self.userHost(for: host))

        OnyxLog.ssh.notice("""
            establishing mux: host=\(host.label, privacy: .public) \
            slot=\(slot, privacy: .public) path=\(slotPath, privacy: .public)
            """)

        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        var exitCode: Int32 = -1
        do {
            try process.run()
            // The -f flag detaches after auth, so the launching process
            // exits within seconds even if the master persists. Bound
            // it anyway in case auth hangs.
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + TimeInterval(Self.connectTimeout + 2))
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()
            process.waitUntilExit()
            killTimer.cancel()
            exitCode = process.terminationStatus
        } catch {
            OnyxLog.ssh.error("""
                establish launch failed: host=\(host.label, privacy: .public) \
                slot=\(slot, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public)
                """)
        }

        let success = exitCode == 0
        if !success {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            OnyxLog.ssh.error("""
                establish FAILED: host=\(host.label, privacy: .public) \
                slot=\(slot, privacy: .public) \
                exit=\(exitCode, privacy: .public) \
                stderr=\(err, privacy: .public)
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
            if success { s.slots[slot].establishedAt = Date() }
            hostStates[host.id] = s
        }
        lock.unlock()
    }

    private static func stopMaster(at path: String, userHost: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(path)", "-O", "exit", userHost]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
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
