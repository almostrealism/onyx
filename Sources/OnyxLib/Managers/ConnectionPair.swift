//
// ConnectionPair.swift
//
// Responsibility: Own EXACTLY two SSH ControlMaster mux masters for one
//                 remote host — one active, one standby — and keep them
//                 warm. Everything the app sends to a host (utility
//                 commands now; interactive terminals once they ride the
//                 pair) travels as mux channels over these two TCP
//                 connections. Hard cap: two connections per host, ever.
// Scope: One instance per remote host, owned by ConnectionPairRegistry.
// Threading: All state mutation happens on the registry's per-host serial
//            queue via `maintain()` / `establish()`. Reads from other
//            threads go through the internal lock (snapshot accessors).
//            The state machine itself is synchronous and side-effect-free
//            except through the injected `PairSSHRunner` — which is what
//            makes it unit-testable without spawning ssh.
//
// Lineage: absorbs the battle-tested mechanics of the old SSHKeeper
// (establish -M -N -f with PID capture, -O check, smoke test, stopMaster
// = -O exit → PID SIGKILL → lsof fallback) and adds: a real slot state
// machine (SlotPhase), a single derived HostHealth that everything reads,
// channel-failure signals from callers, a channel budget for utility
// traffic, and rotation that never yanks a connection out from under
// attached terminals.
//
// Console filter for trace: subsystem:com.onyx category:ssh
//

import Foundation
import Darwin

// MARK: - SSH side-effect boundary (injectable for tests)

/// Every side effect the pair state machine performs, behind a protocol
/// so ConnectionPairTests can drive the machine with scripted outcomes
/// instead of real ssh processes.
public protocol PairSSHRunner {
    /// Run ssh with args, bounded by softTimeout (SIGKILL escalation).
    func run(_ args: [String], softTimeout: TimeInterval, captureStderr: Bool) -> SSHProcess.RunResult
    /// PID of the master owning a control socket, if findable.
    func findMasterPID(socketPath: String) -> pid_t?
    /// SIGKILL + verify death. True if the process died.
    @discardableResult
    func killAndVerify(pid: pid_t) -> Bool
    /// lsof-based master kill by socket path (backup path).
    func killMaster(at path: String, userHost: String)
    func socketExists(atPath: String) -> Bool
    func removeSocket(atPath: String)
    /// Is the pid still alive? (kill(pid, 0) == 0)
    func processAlive(pid: pid_t) -> Bool
}

/// Production runner — thin veneer over SSHProcess + FileManager.
public struct LiveSSHRunner: PairSSHRunner {
    public init() {}
    public func run(_ args: [String], softTimeout: TimeInterval, captureStderr: Bool) -> SSHProcess.RunResult {
        SSHProcess.run(args, softTimeout: softTimeout, captureStderr: captureStderr)
    }
    public func findMasterPID(socketPath: String) -> pid_t? {
        SSHProcess.findMasterPIDs(socketPath: socketPath).first
    }
    @discardableResult
    public func killAndVerify(pid: pid_t) -> Bool {
        SSHProcess.killAndVerify(pid: pid)
    }
    public func killMaster(at path: String, userHost: String) {
        SSHProcess.killMaster(at: path, userHost: userHost)
    }
    public func socketExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    public func removeSocket(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
    public func processAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

// MARK: - Channel budget (per-host utility discipline)

/// Bounds concurrent utility channels per host and dedups identical
/// in-flight polls. sshd's MaxSessions (default 10) counts every mux
/// channel on a connection: N terminals + utility polls must fit. On a
/// slow network the old pollers piled up 2-3× — this is the guard that
/// ends that.
public final class ChannelBudget {
    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private let maxConcurrent: Int

    public init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    /// Try to claim a channel slot. Returns false when the same label is
    /// already in flight (dedup — the previous identical poll hasn't
    /// finished; skip this cycle and keep stale data) or when the host
    /// is at its concurrent-utility cap. NEVER blocks.
    public func acquire(_ label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inFlight.contains(label), inFlight.count < maxConcurrent else { return false }
        inFlight.insert(label)
        return true
    }

    public func release(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(label)
    }

    public var inFlightCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight.count
    }
}

// MARK: - ConnectionPair

public final class ConnectionPair {

    // Cadence/timeout constants.
    //
    // PRIME DIRECTIVE: a working connection is never torn down on
    // suspicion — only on proof. The original 2s-cadence checks with
    // single-sample kill authority ran ~43k times a day; on a stable
    // desktop a false positive was a statistical certainty, and each one
    // murdered a healthy master with every terminal riding it. Sampling
    // is now ADVISORY: only corroborated evidence (consecutive failures)
    // or definitive evidence (the master PROCESS exited — ssh itself
    // declares the TCP dead via ServerAlive and exits) kills a slot.
    public static let tickInterval: TimeInterval = 5
    public static let smokeTestInterval: TimeInterval = 30
    public static let rotationInterval: TimeInterval = 1800
    public static let serverAliveInterval = 10
    public static let serverAliveCountMax = 3
    public static let connectTimeout = 15
    /// Masters never idle-expire (`ControlPersist=0` = forever). Only we
    /// decide when a master dies. The old 600s let an idle master expire
    /// underneath a user who stepped away for ten minutes.
    public static let controlPersist = 0
    /// Consecutive `-O check` failures required before a slot is declared
    /// dead. A single failure is a hiccup (load spike, slow fork), not
    /// evidence.
    public static let checkFailureThreshold = 3
    /// Consecutive smoke-test failures required to declare death.
    public static let smokeFailureThreshold = 2
    /// After this many consecutive establish failures, retry attempts
    /// slow to `establishRetryInterval` so an unreachable host isn't
    /// hammered every tick.
    public static let establishSlowdownAfter = 3
    public static let establishRetryInterval: TimeInterval = 30

    /// One slot of the pair.
    public struct Slot: Equatable {
        public let index: Int
        public let path: String
        public var phase: SlotPhase = .absent
        public var consecutiveFailures: Int = 0
        public var consecutiveSmokeFailures: Int = 0
        public var establishFailures: Int = 0
        public var lastEstablishAttemptAt: Date? = nil
        public var establishedAt: Date? = nil
        public var lastSmokeTestAt: Date? = nil
        public var masterPID: pid_t? = nil
    }

    public let hostID: UUID
    private(set) var host: HostConfig
    private let runner: PairSSHRunner
    private let lock = NSLock()

    private var slots: [Slot]
    private var activeIndex = 0
    private var lastRotationAt: Date? = nil
    private var generation: UInt64 = 0
    /// True once any slot has ever reached .alive — distinguishes
    /// `.connecting` (first contact) from `.down` (lost contact).
    private var hasEverConnected = false
    /// Set by `signalChannelFailure()`; consumed by the next maintain.
    private var pendingChannelFailure = false

    // Overrides set by the registry (sleep/wake + NWPathMonitor).
    private var networkAvailable = true
    private var isSleeping = false

    /// Number of terminal channels currently attached — rotation must
    /// never recycle a connection with live terminals on it. Wired by
    /// the terminal manager once terminals ride the pair; defaults to 0.
    public var terminalChannelCount: () -> Int = { 0 }

    /// Utility-channel discipline for this host.
    public let channelBudget = ChannelBudget()

    /// Fired (on the maintain queue) whenever derived health changes.
    /// The registry re-publishes on main for SwiftUI.
    var onHealthChange: ((HostHealth) -> Void)?

    public init(host: HostConfig, runner: PairSSHRunner = LiveSSHRunner()) {
        self.hostID = host.id
        self.host = host
        self.runner = runner
        self.slots = [
            Slot(index: 0, path: Self.slotPath(for: host.id, slot: 0)),
            Slot(index: 1, path: Self.slotPath(for: host.id, slot: 1)),
        ]
    }

    /// Update host config (port/identity changes) — takes effect on the
    /// next establish.
    func configure(host: HostConfig) {
        lock.lock(); defer { lock.unlock() }
        self.host = host
    }

    // MARK: Public reads (thread-safe snapshots)

    public var health: HostHealth {
        lock.lock(); defer { lock.unlock() }
        return deriveHealthLocked()
    }

    public var activeControlPath: String {
        lock.lock(); defer { lock.unlock() }
        return slots[activeIndex].path
    }

    /// Diagnostic snapshot for the monitor overlay.
    public struct Diagnostics: Equatable {
        public let slots: [Slot]
        public let activeIndex: Int
        public let lastRotationAt: Date?
        public let state: HostConnectionState
    }

    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return Diagnostics(
            slots: slots,
            activeIndex: activeIndex,
            lastRotationAt: lastRotationAt,
            state: deriveHealthLocked().state
        )
    }

    // MARK: Signals

    /// A mux channel request failed (exit 255 / `mux_client_request_session`).
    /// The active connection may be silently dead — mark it suspect so the
    /// next maintain promotes the standby immediately instead of waiting
    /// for the smoke test to notice.
    public func signalChannelFailure() {
        lock.lock()
        pendingChannelFailure = true
        lock.unlock()
        OnyxLog.ssh.notice("""
            channel failure signaled: host=\(self.host.label, privacy: .public) — \
            active slot marked suspect
            """)
    }

    /// System is going to sleep — quiesce. Cleanly exits both masters so
    /// the remote sshd tears sessions down gracefully instead of waiting
    /// for keepalive timeouts after the network vanishes.
    func quiesce() {
        lock.lock()
        isSleeping = true
        let toStop = slots.map { ($0.path, $0.masterPID) }
        for i in slots.indices {
            slots[i].phase = .absent
            slots[i].masterPID = nil
            slots[i].establishedAt = nil
            slots[i].lastSmokeTestAt = nil
        }
        let uh = userHost
        lock.unlock()
        for (path, pid) in toStop {
            stopMaster(at: path, knownPID: pid, userHost: uh)
        }
        publishHealth()
    }

    /// Woke from sleep / network path restored — clear overrides and all
    /// failure counters (a new network is a clean slate; stale establish
    /// backoff must not delay the rebuild); the next maintain
    /// re-validates and rebuilds immediately.
    func reactivate() {
        lock.lock()
        isSleeping = false
        networkAvailable = true
        for i in slots.indices {
            slots[i].consecutiveFailures = 0
            slots[i].consecutiveSmokeFailures = 0
            slots[i].establishFailures = 0
            slots[i].lastEstablishAttemptAt = nil
        }
        lock.unlock()
        publishHealth()
    }

    /// NWPathMonitor verdict. When the path is gone, establishment is
    /// pointless — mark offline so pollers pause and rebuilds stop
    /// burning attempts.
    func setNetworkAvailable(_ available: Bool) {
        lock.lock()
        let changed = networkAvailable != available
        networkAvailable = available
        lock.unlock()
        if changed { publishHealth() }
    }

    /// User-initiated full reset — tear down both slots; next maintain
    /// rebuilds from scratch.
    func reset() {
        OnyxLog.ssh.notice("pair reset: host=\(self.host.label, privacy: .public)")
        lock.lock()
        let toStop = slots.map { ($0.path, $0.masterPID) }
        for i in slots.indices {
            slots[i].phase = .absent
            slots[i].masterPID = nil
            slots[i].establishedAt = nil
            slots[i].lastSmokeTestAt = nil
            slots[i].consecutiveFailures = 0
            slots[i].consecutiveSmokeFailures = 0
            slots[i].establishFailures = 0
            slots[i].lastEstablishAttemptAt = nil
        }
        let uh = userHost
        lock.unlock()
        for (path, pid) in toStop {
            stopMaster(at: path, knownPID: pid, userHost: uh)
            runner.removeSocket(atPath: path)
        }
        publishHealth()
    }

    /// App shutdown — definitively close both masters. Killing the
    /// masters tears down every channel (terminals included) server-side;
    /// local channel clients see EOF and exit cleanly, which is exactly
    /// the teardown SwiftTerm tolerates.
    func shutdown() {
        lock.lock()
        let toStop = slots.map { ($0.path, $0.masterPID) }
        for i in slots.indices { slots[i].phase = .absent }
        let uh = userHost
        lock.unlock()
        for (path, pid) in toStop {
            stopMaster(at: path, knownPID: pid, userHost: uh)
            runner.removeSocket(atPath: path)
        }
    }

    // MARK: Maintain (the state machine tick — runs on the host queue)

    func maintain(now: Date = Date()) {
        lock.lock()
        if isSleeping || !networkAvailable {
            lock.unlock()
            publishHealth()
            return
        }
        var s = slots
        let channelFailure = pendingChannelFailure
        pendingChannelFailure = false
        let uh = userHost
        lock.unlock()

        // 1. DEFINITIVE evidence first: is the master PROCESS still
        //    running? ssh exits on its own when ServerAlive declares the
        //    TCP dead — process death is proof, not suspicion, and it
        //    costs one kill(pid, 0), no ssh spawn. This is the primary
        //    death detector; everything below is advisory.
        for i in s.indices where s[i].phase == .alive || s[i].phase == .suspect {
            if let pid = s[i].masterPID, !runner.processAlive(pid: pid) {
                OnyxLog.ssh.notice("""
                    master process exited: host=\(self.host.label, privacy: .public) \
                    slot=\(i, privacy: .public) pid=\(pid, privacy: .public) — definitive death
                    """)
                s[i].phase = .dead
                s[i].masterPID = nil
            }
        }

        // 2. ADVISORY: cheap socket-level check on live slots. A single
        //    failure is a hiccup (load spike, slow fork, busy mux) — it
        //    is logged and counted, and ONLY a run of
        //    `checkFailureThreshold` consecutive failures kills the slot.
        //    The old single-sample kill authority is what murdered
        //    healthy connections on stable desktops.
        for i in s.indices where s[i].phase != .establishing {
            let exists = runner.socketExists(atPath: s[i].path)
            let alive = exists && checkAlive(path: s[i].path, userHost: uh)
            switch s[i].phase {
            case .alive, .suspect:
                if alive {
                    s[i].consecutiveFailures = 0
                } else if !exists && s[i].masterPID == nil {
                    // Socket gone AND no process — definitively gone.
                    s[i].phase = .absent
                } else {
                    s[i].consecutiveFailures += 1
                    OnyxLog.ssh.notice("""
                        check failed (\(s[i].consecutiveFailures, privacy: .public)/\(Self.checkFailureThreshold, privacy: .public)): \
                        host=\(self.host.label, privacy: .public) slot=\(i, privacy: .public)
                        """)
                    if s[i].consecutiveFailures >= Self.checkFailureThreshold {
                        OnyxLog.ssh.notice("slot \(i, privacy: .public) died (corroborated): host=\(self.host.label, privacy: .public)")
                        s[i].phase = .dead
                    }
                }
            case .dead, .absent:
                // A dead slot that answers again (e.g. master survived a
                // transient stall) is welcomed back — never waste a
                // working connection. But only with a VERIFIED live
                // master process: a stale socket answering on behalf of
                // an exited master must not resurrect the slot.
                if alive,
                   let pid = runner.findMasterPID(socketPath: s[i].path),
                   runner.processAlive(pid: pid) {
                    s[i].phase = .alive
                    s[i].masterPID = pid
                    s[i].consecutiveFailures = 0
                    s[i].consecutiveSmokeFailures = 0
                    OnyxLog.ssh.info("slot \(i, privacy: .public) alive: host=\(self.host.label, privacy: .public)")
                }
            case .establishing:
                break
            }
        }

        // 3. Channel-failure signal → active slot is suspect even if the
        //    IPC check passed (the socket can answer while TCP is dead).
        //    Suspect triggers an immediate smoke test below; a 255 alone
        //    never kills anything.
        if channelFailure, s[activeIndexSnapshot()].phase == .alive {
            s[activeIndexSnapshot()].phase = .suspect
        }

        // 4. ADVISORY: smoke test — a real command through each live slot
        //    on a slow cadence (suspect slots immediately). Needs
        //    `smokeFailureThreshold` consecutive failures to kill: one
        //    failure marks suspect, the next maintain re-tests, and only
        //    a second consecutive failure (corroboration) declares death.
        for i in s.indices where s[i].phase == .alive || s[i].phase == .suspect {
            let last = s[i].lastSmokeTestAt ?? .distantPast
            let due = now.timeIntervalSince(last) >= Self.smokeTestInterval
            guard due || s[i].phase == .suspect else { continue }
            s[i].lastSmokeTestAt = now
            if smokeTest(path: s[i].path, userHost: uh) {
                s[i].phase = .alive
                s[i].consecutiveSmokeFailures = 0
            } else {
                s[i].consecutiveSmokeFailures += 1
                OnyxLog.ssh.notice("""
                    smoke test failed (\(s[i].consecutiveSmokeFailures, privacy: .public)/\(Self.smokeFailureThreshold, privacy: .public)): \
                    host=\(self.host.label, privacy: .public) slot=\(i, privacy: .public)
                    """)
                if s[i].consecutiveSmokeFailures >= Self.smokeFailureThreshold {
                    s[i].phase = .dead
                } else {
                    s[i].phase = .suspect
                }
            }
        }

        // Commit check results + promotion + rotation under the lock.
        // NB: terminalChannelCount is evaluated BEFORE taking the pair
        // lock — it calls into the registry (its own lock), and the
        // registry calls pair methods while holding its lock; taking
        // pair→registry here would be an ABBA deadlock.
        let attachedTerminals = terminalChannelCount()
        var toEstablish: [Int] = []
        var rotationTeardown: (path: String, pid: pid_t?)? = nil
        lock.lock()
        slots = s

        // 5. Promotion: active PROVEN dead (never merely suspect — a
        //    suspect slot is under investigation, and flapping the
        //    active path on a single hiccup is exactly the twitchiness
        //    that wrecked stable desktops), standby alive → swap. The
        //    standby is warm, so the moment the active is proven dead
        //    there is already a working authenticated connection to ride.
        if slots[activeIndex].phase != .alive, slots[activeIndex].phase != .suspect,
           slots[1 - activeIndex].phase == .alive {
            let old = activeIndex
            activeIndex = 1 - activeIndex
            generation &+= 1
            OnyxLog.ssh.notice("""
                PAIR FAILOVER: host=\(self.host.label, privacy: .public) \
                slot \(old, privacy: .public) → slot \(self.activeIndex, privacy: .public)
                """)
        }

        // 6. Pre-emptive rotation — ONLY when no terminals are attached.
        //    Rotation is a planned failover; doing it under live terminal
        //    channels would blip every terminal for freshness's sake.
        //    The clock starts when the pair first becomes fully alive —
        //    a nil start previously read as .distantPast, which fired a
        //    pointless rotation (connection recycle) right at startup.
        if slots[0].phase == .alive && slots[1].phase == .alive,
           attachedTerminals == 0 {
            if lastRotationAt == nil { lastRotationAt = now }
            let last = lastRotationAt ?? now
            if now.timeIntervalSince(last) >= Self.rotationInterval {
                let oldActive = activeIndex
                activeIndex = 1 - activeIndex
                lastRotationAt = now
                generation &+= 1
                OnyxLog.ssh.notice("""
                    PAIR ROTATION: host=\(self.host.label, privacy: .public) \
                    slot \(oldActive, privacy: .public) → slot \(self.activeIndex, privacy: .public)
                    """)
                rotationTeardown = (slots[oldActive].path, slots[oldActive].masterPID)
                slots[oldActive].phase = .absent
                slots[oldActive].masterPID = nil
                slots[oldActive].establishedAt = nil
                slots[oldActive].lastSmokeTestAt = nil
            }
        }

        if slots.contains(where: { $0.phase == .alive }) { hasEverConnected = true }

        // 7. Collect rebuild targets — with backoff. After
        //    `establishSlowdownAfter` consecutive failed establishes,
        //    retry at most every `establishRetryInterval` so an
        //    unreachable host isn't hammered every tick.
        for i in slots.indices where slots[i].phase == .dead || slots[i].phase == .absent {
            if slots[i].establishFailures >= Self.establishSlowdownAfter,
               let lastAttempt = slots[i].lastEstablishAttemptAt,
               now.timeIntervalSince(lastAttempt) < Self.establishRetryInterval {
                continue
            }
            toEstablish.append(i)
        }
        lock.unlock()
        publishHealth()

        if let t = rotationTeardown {
            stopMaster(at: t.path, knownPID: t.pid, userHost: uh)
            runner.removeSocket(atPath: t.path)
        }

        // 7. Rebuild dead slots (bounded; still on the host queue so a
        //    stuck establish only stalls this host).
        for i in toEstablish {
            establish(slot: i)
        }
    }

    private func activeIndexSnapshot() -> Int {
        lock.lock(); defer { lock.unlock() }
        return activeIndex
    }

    // MARK: Establish / teardown

    /// Extra args appended to the master's establish command — e.g. the
    /// MCP `-R` reverse forwarding once terminals ride the pair (mux
    /// clients can't reliably request forwardings at channel-open time;
    /// they belong to the master).
    public var masterExtraArgs: () -> [String] = { [] }

    private func establish(slot index: Int) {
        lock.lock()
        guard slots[index].phase == .dead || slots[index].phase == .absent else {
            lock.unlock()
            return
        }
        guard !isSleeping, networkAvailable else {
            lock.unlock()
            return
        }
        slots[index].phase = .establishing
        slots[index].lastEstablishAttemptAt = Date()
        let path = slots[index].path
        let oldPID = slots[index].masterPID
        slots[index].masterPID = nil
        let h = host
        let uh = userHost
        lock.unlock()
        publishHealth()

        // Definitively close any prior master on this slot first — the
        // old master otherwise keeps its TCP connection to the remote
        // sshd open forever (docs/ssh-connection-leak.md).
        stopMaster(at: path, knownPID: oldPID, userHost: uh)

        var args: [String] = [
            "-M", "-N", "-f",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(path)",
            "-o", "ControlPersist=\(Self.controlPersist)",
            "-o", "ServerAliveInterval=\(Self.serverAliveInterval)",
            "-o", "ServerAliveCountMax=\(Self.serverAliveCountMax)",
            "-o", "ConnectTimeout=\(Self.connectTimeout)",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if h.ssh.port != 22 { args += ["-p", "\(h.ssh.port)"] }
        if !h.ssh.identityFile.isEmpty { args += ["-i", h.ssh.identityFile] }
        args += masterExtraArgs()
        args.append(uh)

        OnyxLog.ssh.notice("""
            establishing master: host=\(h.label, privacy: .public) \
            slot=\(index, privacy: .public)
            """)
        let result = runner.run(args,
                                softTimeout: TimeInterval(Self.connectTimeout + 2),
                                captureStderr: true)

        // The -f fork can fail silently even on exit 0 — verify with a
        // real -O check before claiming success, and capture the master
        // PID while the socket file is fresh (it's the only reliable
        // handle for killing a master stuck in kernel D state later).
        var success = result.exit == 0
        var capturedPID: pid_t? = nil
        if success {
            success = checkAlive(path: path, userHost: uh)
            if success {
                capturedPID = runner.findMasterPID(socketPath: path)
            }
        }

        if !success {
            OnyxLog.ssh.error("""
                establish FAILED: host=\(h.label, privacy: .public) \
                slot=\(index, privacy: .public) \
                exit=\(result.exit, privacy: .public) \
                timedOut=\(result.timedOut, privacy: .public) \
                stderr=\(result.stderr, privacy: .public)
                """)
        } else {
            OnyxLog.ssh.info("""
                master established: host=\(h.label, privacy: .public) \
                slot=\(index, privacy: .public)
                """)
        }

        lock.lock()
        slots[index].phase = success ? .alive : .absent
        slots[index].establishedAt = success ? Date() : nil
        slots[index].masterPID = capturedPID
        slots[index].lastSmokeTestAt = nil
        if success {
            slots[index].establishFailures = 0
            slots[index].consecutiveFailures = 0
            slots[index].consecutiveSmokeFailures = 0
            hasEverConnected = true
            generation &+= 1
        } else {
            slots[index].establishFailures += 1
        }
        lock.unlock()
        publishHealth()
    }

    /// -O exit → direct PID SIGKILL → lsof fallback. Same escalation
    /// discipline as the old SSHKeeper.stopMaster.
    private func stopMaster(at path: String, knownPID: pid_t?, userHost: String) {
        if runner.socketExists(atPath: path) {
            _ = runner.run([
                "-o", "ControlPath=\(path)",
                "-O", "exit",
                userHost,
            ], softTimeout: 2, captureStderr: false)
        }
        if let pid = knownPID, runner.processAlive(pid: pid) {
            runner.killAndVerify(pid: pid)
        }
        runner.killMaster(at: path, userHost: userHost)
    }

    private func checkAlive(path: String, userHost: String) -> Bool {
        let r = runner.run([
            "-o", "ControlPath=\(path)",
            "-O", "check",
            userHost,
        ], softTimeout: 2, captureStderr: false)
        return r.exit == 0
    }

    private func smokeTest(path: String, userHost: String) -> Bool {
        guard runner.socketExists(atPath: path) else { return false }
        let r = runner.run([
            "-o", "ControlPath=\(path)",
            "-o", "BatchMode=yes",
            userHost, "true",
        ], softTimeout: 3, captureStderr: false)
        return r.exit == 0
    }

    // MARK: Health derivation

    private func deriveHealthLocked() -> HostHealth {
        let state: HostConnectionState
        if isSleeping {
            state = .sleeping
        } else if !networkAvailable {
            state = .offline
        } else {
            let active = slots[activeIndex].phase
            let standby = slots[1 - activeIndex].phase
            switch active {
            case .alive:
                state = standby == .alive ? .connected : .degraded
            case .suspect:
                state = .failing
            case .establishing, .dead, .absent:
                state = hasEverConnected ? .down : .connecting
            }
        }
        return HostHealth(
            hostID: hostID,
            state: state,
            activeSlotPhase: slots[activeIndex].phase,
            standbySlotPhase: slots[1 - activeIndex].phase,
            activeControlPath: slots[activeIndex].path,
            generation: generation,
            lastTransition: Date()
        )
    }

    private var lastPublishedState: HostConnectionState?
    private func publishHealth() {
        lock.lock()
        let h = deriveHealthLocked()
        let changed = h.state != lastPublishedState
        lastPublishedState = h.state
        lock.unlock()
        if changed { onHealthChange?(h) }
    }

    // MARK: Paths

    private var userHost: String {
        host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
    }

    /// Per-slot control path under ~/.ssh/onyx-mux/. Slot 0's path
    /// matches the legacy single-slot path so existing sockets/cleanup
    /// tooling keep working unchanged.
    public static func slotPath(for hostID: UUID, slot: Int) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".ssh/onyx-mux")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name: String
        switch slot {
        case 0: name = "mux-\(hostID.uuidString)"
        case 1: name = "mux-\(hostID.uuidString)-spare"
        default: name = "mux-\(hostID.uuidString)-slot\(slot)"
        }
        return dir.appendingPathComponent(name).path
    }
}
