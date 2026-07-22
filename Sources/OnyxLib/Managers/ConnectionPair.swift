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

    // Cadence/timeout constants — carried over from SSHKeeper unchanged;
    // they were tuned in production.
    public static let tickInterval: TimeInterval = 2
    public static let smokeTestInterval: TimeInterval = 4
    public static let rotationInterval: TimeInterval = 1800
    public static let serverAliveInterval = 10
    public static let serverAliveCountMax = 3
    public static let connectTimeout = 15
    public static let controlPersist = 600

    /// One slot of the pair.
    public struct Slot: Equatable {
        public let index: Int
        public let path: String
        public var phase: SlotPhase = .absent
        public var consecutiveFailures: Int = 0
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

    /// Woke from sleep / network path restored — clear overrides; the
    /// next maintain re-validates and rebuilds immediately.
    func reactivate() {
        lock.lock()
        isSleeping = false
        networkAvailable = true
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

        // 1. Cheap socket-level check on each non-establishing slot.
        for i in s.indices where s[i].phase != .establishing {
            let exists = runner.socketExists(atPath: s[i].path)
            let alive = exists && checkAlive(path: s[i].path, userHost: uh)
            switch (alive, s[i].phase) {
            case (true, .alive), (true, .suspect):
                break // suspect stays suspect until the smoke test clears it below
            case (true, _):
                s[i].phase = .alive
                s[i].consecutiveFailures = 0
                OnyxLog.ssh.info("slot \(i, privacy: .public) alive: host=\(self.host.label, privacy: .public)")
            case (false, .alive), (false, .suspect):
                s[i].phase = exists ? .dead : .absent
                s[i].consecutiveFailures += 1
                OnyxLog.ssh.notice("slot \(i, privacy: .public) died: host=\(self.host.label, privacy: .public)")
            case (false, _):
                s[i].phase = exists ? .dead : .absent
                s[i].consecutiveFailures += 1
            }
        }

        // 2. Channel-failure signal → active slot is suspect even if the
        //    IPC check passed (the socket can answer while TCP is dead).
        if channelFailure, s[activeIndexSnapshot()].phase == .alive {
            s[activeIndexSnapshot()].phase = .suspect
        }

        // 3. Smoke test — real command through each alive/suspect slot on
        //    its cadence; catches silent TCP death `-O check` can't see.
        for i in s.indices where s[i].phase == .alive || s[i].phase == .suspect {
            let last = s[i].lastSmokeTestAt ?? .distantPast
            let due = now.timeIntervalSince(last) >= Self.smokeTestInterval
            // A suspect slot is always re-tested immediately.
            guard due || s[i].phase == .suspect else { continue }
            s[i].lastSmokeTestAt = now
            if smokeTest(path: s[i].path, userHost: uh) {
                s[i].phase = .alive
            } else {
                OnyxLog.ssh.notice("""
                    smoke test FAILED: host=\(self.host.label, privacy: .public) \
                    slot=\(i, privacy: .public) — socket alive but command hung; \
                    marking dead for rebuild
                    """)
                s[i].phase = .dead
                s[i].consecutiveFailures += 1
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

        // 4. Promotion: active unusable, standby alive → swap. This is
        //    the zero-downtime rotation — the standby is warm, so the
        //    moment the active dies there is already a working
        //    authenticated TCP connection to ride.
        if slots[activeIndex].phase != .alive, slots[1 - activeIndex].phase == .alive {
            let old = activeIndex
            activeIndex = 1 - activeIndex
            generation &+= 1
            OnyxLog.ssh.notice("""
                PAIR FAILOVER: host=\(self.host.label, privacy: .public) \
                slot \(old, privacy: .public) → slot \(self.activeIndex, privacy: .public)
                """)
        }

        // 5. Pre-emptive rotation — ONLY when no terminals are attached.
        //    Rotation is a planned failover; doing it under live terminal
        //    channels would blip every terminal for freshness's sake.
        if slots[0].phase == .alive && slots[1].phase == .alive,
           attachedTerminals == 0 {
            let last = lastRotationAt ?? .distantPast
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

        // 6. Collect rebuild targets.
        for i in slots.indices where slots[i].phase == .dead || slots[i].phase == .absent {
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
            hasEverConnected = true
            generation &+= 1
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
