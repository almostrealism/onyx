//
// ConnectionPairRegistry.swift
//
// Responsibility: Own one ConnectionPair per remote host. Drives the
//                 2s maintenance tick, publishes per-host health for
//                 SwiftUI, runs the orphan-master reaper, and owns the
//                 app-lifecycle hooks (shutdown, reapAll). Sleep/wake
//                 and NWPathMonitor integration land here too.
// Scope: Shared singleton (ConnectionPairRegistry.shared) — replaces
//        SSHKeeper.shared.
// Threading: Tick fires on main; per-host maintenance runs on per-host
//            serial queues with an `enqueued` dedup set (one in-flight
//            maintenance per host, ever — a stuck ssh call stalls only
//            its own host).
//
// Console filter for trace: subsystem:com.onyx category:ssh
//

import Foundation
import Darwin
import Network
import AppKit

public final class ConnectionPairRegistry: ObservableObject {

    public static let shared = ConnectionPairRegistry()

    /// Bumped whenever any pair's health changes — SwiftUI diagnostic
    /// views observe this for re-render.
    @Published public private(set) var stateGeneration: UInt64 = 0
    /// Latest health snapshot per host, published on main.
    @Published public private(set) var healthByHost: [UUID: HostHealth] = [:]

    private var pairs: [UUID: ConnectionPair] = [:]
    private let lock = NSLock()
    private var appState: AppState?
    private var timer: Timer?
    private var hostQueues: [UUID: DispatchQueue] = [:]
    private var enqueued: Set<UUID> = []
    private var orphanReapInFlight = false
    /// Kill switch, togglable from the mux diagnostic panel.
    public private(set) var enabled: Bool = true

    /// Running terminal channels per host — published by the terminal
    /// session manager(s) whenever their pools change. Rotation reads
    /// this so a planned failover never blips live terminals.
    private var terminalCounts: [UUID: Int] = [:]

    /// Event-driven network awareness. On path loss the pairs go
    /// `.offline` immediately (pollers pause, establishes stop) instead
    /// of burning 45s keepalive timeouts; on restore they validate and
    /// rebuild at once.
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.onyx.pair.nwpath", qos: .utility)
    private var sleepObserver: Any?
    private var wakeObserver: Any?

    private init() {}

    // MARK: - Lifecycle

    /// Start the supervisor. Idempotent. No-op under XCTest so unit
    /// tests never spawn ssh.
    public func start(appState: AppState) {
        if NSClassFromString("XCTest") != nil { return }
        guard timer == nil else { return }
        self.appState = appState
        OnyxLog.ssh.info("ConnectionPairRegistry starting (tick=\(ConnectionPair.tickInterval, privacy: .public)s)")

        DispatchQueue.main.async { [weak self] in self?.tick() }
        let t = Timer(timeInterval: ConnectionPair.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        startNetworkMonitor()
        installSleepWakeObservers()
    }

    /// NWPathMonitor: push network-path verdicts into every pair the
    /// moment they change — no waiting for keepalive timeouts.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            OnyxLog.ssh.notice("NWPath: \(satisfied ? "satisfied" : "unsatisfied", privacy: .public)")
            self.lock.lock()
            let all = Array(self.pairs.values)
            self.lock.unlock()
            for pair in all {
                pair.setNetworkAvailable(satisfied)
            }
            if satisfied {
                // Path restored — validate/rebuild immediately instead of
                // waiting up to a full tick.
                DispatchQueue.main.async { [weak self] in self?.tick() }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    /// willSleep: cleanly exit both masters per host so the remote sshd
    /// tears sessions down gracefully BEFORE the network vanishes —
    /// nothing left to time out, nothing orphaned server-side.
    /// didWake: clear overrides and rebuild the pairs immediately.
    private func installSleepWakeObservers() {
        guard sleepObserver == nil else { return }
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            OnyxLog.ssh.notice("willSleep — quiescing all pairs")
            self.lock.lock()
            let all = Array(self.pairs.values)
            self.lock.unlock()
            // Quiesce synchronously-ish on a background queue; the OS
            // gives us a short window before actually sleeping.
            DispatchQueue.global(qos: .userInitiated).async {
                for pair in all { pair.quiesce() }
            }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            OnyxLog.ssh.notice("didWake — reactivating all pairs")
            self.lock.lock()
            let all = Array(self.pairs.values)
            self.lock.unlock()
            for pair in all { pair.reactivate() }
            // Rebuild immediately — don't wait for the next tick.
            self.tick()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        OnyxLog.ssh.info("ConnectionPairRegistry stopped")
    }

    /// Shutdown — close both masters of every pair, definitively.
    /// Killing the masters tears down every mux channel server-side;
    /// nothing is left holding remote TCP connections. Idempotent and
    /// bounded (each stopMaster call is timeout-escalated).
    public func shutdown() {
        OnyxLog.ssh.notice("ConnectionPairRegistry shutdown — closing all masters")
        setEnabled(false)
        timer?.invalidate()
        timer = nil

        lock.lock()
        let all = Array(pairs.values)
        pairs.removeAll()
        lock.unlock()

        for pair in all {
            pair.shutdown()
        }
        OnyxLog.ssh.notice("ConnectionPairRegistry shutdown complete")
    }

    /// Emergency kill switch for the supervisor.
    public func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
        OnyxLog.ssh.notice("ConnectionPairRegistry \(value ? "ENABLED" : "DISABLED", privacy: .public)")
    }

    // MARK: - Access

    /// The pair for a host, created on first use.
    public func pair(for host: HostConfig) -> ConnectionPair {
        lock.lock(); defer { lock.unlock() }
        if let p = pairs[host.id] {
            p.configure(host: host)
            return p
        }
        let p = ConnectionPair(host: host)
        p.onHealthChange = { [weak self] health in
            DispatchQueue.main.async {
                self?.healthByHost[health.hostID] = health
                self?.stateGeneration &+= 1
            }
        }
        // Rotation gate: never recycle a connection with live terminals.
        let hostID = host.id
        p.terminalChannelCount = { [weak self] in
            self?.terminalCount(for: hostID) ?? 0
        }
        // MCP reverse forwarding is established at the master level so
        // every channel (terminals included) shares it.
        p.masterExtraArgs = { [weak self] in
            self?.appState?.mcpMasterForwardingFlags() ?? []
        }
        pairs[host.id] = p
        return p
    }

    // MARK: - Terminal channel accounting

    /// Latest per-host running-terminal counts, per reporting manager
    /// (one terminal manager per window — counts are summed across them).
    private var countsByReporter: [ObjectIdentifier: [UUID: Int]] = [:]

    /// Called by a terminal session manager whenever its pool changes.
    public func updateTerminalCounts(_ counts: [UUID: Int], reporter: AnyObject) {
        lock.lock()
        countsByReporter[ObjectIdentifier(reporter)] = counts
        terminalCounts = countsByReporter.values.reduce(into: [:]) { acc, per in
            for (hid, n) in per { acc[hid, default: 0] += n }
        }
        lock.unlock()
    }

    private func terminalCount(for hostID: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return terminalCounts[hostID] ?? 0
    }

    /// Synchronous health read. `.initializing` if the pair hasn't been
    /// created yet.
    public func health(for host: HostConfig) -> HostHealth {
        lock.lock()
        let p = pairs[host.id]
        lock.unlock()
        guard let p else {
            return HostHealth(
                hostID: host.id,
                state: .initializing,
                activeSlotPhase: .absent,
                standbySlotPhase: .absent,
                activeControlPath: ConnectionPair.slotPath(for: host.id, slot: 0),
                generation: 0,
                lastTransition: Date()
            )
        }
        return p.health
    }

    /// ControlPath of the host's currently-active slot. Always returns
    /// something — slot 0's default path before the pair exists (matches
    /// the legacy single-slot path).
    public func controlPath(for host: HostConfig) -> String {
        lock.lock()
        let p = pairs[host.id]
        lock.unlock()
        return p?.activeControlPath ?? ConnectionPair.slotPath(for: host.id, slot: 0)
    }

    /// Cached liveness — synchronous, no ssh call.
    public func isMuxAlive(for host: HostConfig) -> Bool {
        health(for: host).state.isUsable && health(for: host).activeSlotPhase == .alive
    }

    /// Diagnostic snapshot for the monitor overlay, if the pair exists.
    public func pairDiagnostics(for host: HostConfig) -> ConnectionPair.Diagnostics? {
        lock.lock()
        let p = pairs[host.id]
        lock.unlock()
        return p?.diagnostics
    }

    /// User-initiated reset of a host's pair.
    public func reset(for host: HostConfig) {
        lock.lock()
        let p = pairs[host.id]
        lock.unlock()
        p?.reset()
    }

    /// Remove and tear down a host's pair (host deleted from config).
    /// Teardown runs on a background queue — stopMaster is bounded but
    /// can take seconds, and this is called from the main-thread tick.
    public func removePair(for hostID: UUID) {
        lock.lock()
        let p = pairs.removeValue(forKey: hostID)
        hostQueues.removeValue(forKey: hostID)
        lock.unlock()
        if let p {
            DispatchQueue.global(qos: .utility).async { p.shutdown() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.healthByHost.removeValue(forKey: hostID)
            self?.stateGeneration &+= 1
        }
    }

    // MARK: - Nuclear cleanup / diagnostics

    /// Kill every ssh master with a ControlPath under ~/.ssh/onyx-mux/,
    /// drain the RemoteExec registry, sweep socket files. In-app
    /// equivalent of Scripts/ssh-leak-cleanup.sh.
    @discardableResult
    public func reapAll() -> (killed: Int, refused: Int) {
        OnyxLog.ssh.notice("reapAll: nuclear cleanup requested")

        lock.lock()
        let all = Array(pairs.values)
        pairs.removeAll()
        lock.unlock()
        for pair in all { pair.shutdown() }

        let muxDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux").path
        let dirResult = SSHProcess.reapAllInDir(muxDir)
        let execResult = RemoteExec.shared.reapAll()
        let result = (killed: dirResult.killed + execResult.killed,
                      refused: dirResult.refused + execResult.refused)
        OnyxLog.ssh.notice("""
            reapAll done: killed=\(result.killed, privacy: .public) \
            refused=\(result.refused, privacy: .public)
            """)
        return result
    }

    /// Ground-truth inventory of ssh processes + sockets + pair state.
    public func inventoryDump() -> String {
        let muxDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux").path
        var dump = SSHProcess.inventoryDump(muxDir: muxDir)

        dump += "\n\n=== RemoteExec tracked PIDs ===\n"
        dump += RemoteExec.shared.inventoryDump()

        lock.lock()
        let snapshot = pairs
        lock.unlock()
        dump += "\n\n=== Pair state ===\n"
        if snapshot.isEmpty {
            dump += "  (no pairs tracked)\n"
        }
        for (hid, pair) in snapshot {
            let d = pair.diagnostics
            dump += "  host \(hid.uuidString.prefix(8)) state=\(d.state) active=slot\(d.activeIndex)\n"
            for slot in d.slots {
                let pidStr = slot.masterPID.map { "pid \($0)" } ?? "no pid"
                dump += "    slot\(slot.index) \(slot.phase) \(pidStr)\n"
                dump += "      path=\(slot.path)\n"
            }
        }
        OnyxLog.ssh.notice("inventoryDump:\n\(dump, privacy: .public)")
        return dump
    }

    // MARK: - Tick

    private func hostQueue(for hostID: UUID) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = hostQueues[hostID] { return q }
        let q = DispatchQueue(label: "com.onyx.pair.host.\(hostID.uuidString.prefix(8))",
                              qos: .userInitiated)
        hostQueues[hostID] = q
        return q
    }

    private func tick() {
        guard enabled, let appState = appState else { return }
        let hosts = appState.hosts.filter { !$0.isLocal }
        for host in hosts {
            // One in-flight maintenance per host, ever — this dedup is
            // what killed the dispatch-pool exhaustion the old concurrent
            // queue caused when ssh calls hung.
            lock.lock()
            if enqueued.contains(host.id) {
                lock.unlock()
                continue
            }
            enqueued.insert(host.id)
            lock.unlock()

            let pair = self.pair(for: host)
            hostQueue(for: host.id).async { [weak self] in
                pair.maintain()
                self?.lock.lock()
                self?.enqueued.remove(host.id)
                self?.lock.unlock()
            }
        }

        // Reap pairs for hosts that were removed from config.
        lock.lock()
        let known = Set(hosts.map { $0.id })
        let stale = pairs.keys.filter { !known.contains($0) }
        lock.unlock()
        for hid in stale { removePair(for: hid) }

        // Orphan reaper — catches masters that outlived their socket
        // files (kernel D state etc.) and keeps holding remote TCP
        // connections. Deduplicated like host maintenance.
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

    /// SIGKILL any ssh master under ~/.ssh/onyx-mux/ whose ControlPath
    /// isn't one of our current slots.
    private func reapOrphanMasters() {
        lock.lock()
        var current = Set<String>()
        for pair in pairs.values {
            for slot in pair.diagnostics.slots { current.insert(slot.path) }
        }
        lock.unlock()

        let muxDirPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/onyx-mux").path

        let processes = SSHProcess.findAllSSHMastersInDir(muxDirPrefix)
        var reaped = 0
        for (pid, path) in processes {
            if current.contains(path) { continue }
            if SSHProcess.killAndVerify(pid: pid) { reaped += 1 } else {
                OnyxLog.ssh.error("""
                    orphan reap: pid \(pid, privacy: .public) refused SIGKILL — \
                    probably kernel D state; retrying next cycle
                    """)
            }
        }
        if reaped > 0 {
            OnyxLog.ssh.notice("orphan reap: killed \(reaped, privacy: .public) leaked master(s)")
        }
    }
}
