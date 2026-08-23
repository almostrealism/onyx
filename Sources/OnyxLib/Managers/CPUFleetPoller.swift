//
// CPUFleetPoller.swift
//
// Responsibility: Periodically samples CPU% on every configured host
//                 (localhost + each HostConfig) and pushes results into
//                 CPUStreamStore so the screensaver has fresh data. This
//                 is a deliberately lightweight superset of MonitorManager,
//                 which only polls the *active* host — the fleet poller
//                 covers dormant hosts the user isn't looking at right now.
// Scope: Shared singleton (CPUFleetPoller.shared). One poller per app
//        process; subsequent start() calls are no-ops while already
//        running, so it's safe to call from every AppState's launch path.
// Threading: Timer fires on main; each per-host SSH call runs on a
//            utility-QoS background queue. Results land in
//            CPUStreamStore.shared which is itself thread-safe.
// Invariants:
//   - At most one Timer is alive at any time
//   - Per-host SSH calls have a hard 8s kill timer (must be < tick interval
//     so a single hung host doesn't block the next round)
//   - Hosts whose SSH mux is dead are skipped — we don't want to spin up
//     fresh control masters from the screensaver path
//

import AppKit
import Foundation

/// Polls CPU% on every connected host and feeds the screensaver stream.
public final class CPUFleetPoller {

    /// Tick interval. 10s is a sweet spot for the screensaver: the totem
    /// scroll rate stays gentle and we don't add real load to the user's
    /// fleet — at this cadence one CPU sample costs about as much as the
    /// SSH keepalive that's already happening.
    public static let tickInterval: TimeInterval = 10

    /// Per-call wall-clock cap. Must stay strictly less than tickInterval
    /// so a single hung host can't push the next round.
    public static let perHostTimeout: TimeInterval = 8

    /// How long a container stays "visible" after its last >=1% CPU
    /// sample. Matches DockerStatsManager.visibilityWindow so the
    /// screensaver and the in-app monitor agree on which containers are
    /// considered idle.
    public static let containerActivityWindow: TimeInterval = 300

    /// Activity threshold for "this container is doing something" —
    /// matches DockerStatsManager's >=1% rule.
    public static let containerActivityThreshold: Double = 1.0

    /// How often to re-probe AMD GPUs, per host.
    ///
    /// The stats script can only see nvidia (and Apple's ioreg); an AMD
    /// card is invisible to it, because folding the amdgpu sysfs walk in
    /// blew the script past what a remote terminal accepts and cost every
    /// Mac its stats. So it's a second, small call — and a second call
    /// per host per 10s tick is exactly the poll pileup this codebase
    /// keeps getting bitten by. Every third tick is the compromise.
    public static let acceleratorInterval: TimeInterval = 30

    /// How long an AMD reading is carried forward between probes.
    ///
    /// Without this the 20s chart buckets would show holes wherever a
    /// tick fell between probes, and a busy GPU would strobe. With it, a
    /// host that stops answering goes blank after two missed probes
    /// rather than showing a maxed-out card that isn't there any more.
    public static let acceleratorStaleAfter: TimeInterval = 75

    public static let shared = CPUFleetPoller()

    private weak var appState: AppState?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.onyx.cpu-fleet-poller",
                                      qos: .utility, attributes: .concurrent)

    /// `hostID:containerName` → last time CPU >= 1%. Guarded by `stateLock`
    /// because pollOne can fire concurrently for multiple hosts on the
    /// shared `queue`. Pruned to bound memory.
    private var lastContainerActivity: [String: Date] = [:]
    /// hostID → when we last ASKED about its AMD GPU (claimed before the
    /// call, so a slow probe can't be started twice).
    private var lastAcceleratorProbe: [String: Date] = [:]
    /// hostID → last AMD GPU reading and when it arrived.
    private var lastAMDGPU: [String: (value: Double, at: Date)] = [:]
    private let stateLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    /// Start polling. Safe to call repeatedly — a second call while already
    /// running is a no-op. The first AppState to call this becomes the
    /// "owner"; if it dies, the timer falls quiet on the next tick.
    ///
    /// No-op when running under XCTest so unit tests don't kick off a real
    /// SSH fan-out or write to the user's Application Support directory.
    public func start(appState: AppState) {
        if NSClassFromString("XCTest") != nil { return }

        if let existing = self.appState, existing === appState, timer != nil { return }

        // If a prior owner is gone, take over. If a prior owner is alive
        // but a different AppState, prefer the new one (later starts are
        // more "current").
        self.appState = appState

        guard timer == nil else { return }

        // First tick immediately so the screensaver doesn't sit on an empty
        // file for 10s after the app launches.
        DispatchQueue.main.async { [weak self] in self?.tick() }
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop polling. Used for tests; production never stops once started.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Per-tick fan-out

    private func tick() {
        guard let appState = appState else {
            // Owner went away — stop polling and wait for someone to restart.
            stop()
            return
        }

        // Always include localhost — it's not in appState.hosts, but the user
        // explicitly asked for it.
        var targets: [HostConfig] = [HostConfig.localhost]
        targets.append(contentsOf: appState.hosts)

        let timestamp = Date().timeIntervalSince1970

        for host in targets {
            queue.async { [weak self] in
                self?.pollOne(host: host, appState: appState, timestamp: timestamp)
            }
        }

        // Hours worked this week (via Timing.app). Pushed alongside CPU so
        // the screensaver can size + color its central gravity ball.
        // Read on main (where the timer fires) — these are @Published.
        if appState.timing.isConfigured {
            let hours = appState.timing.totalWeekHours
            CPUStreamStore.shared.setWeeklyHours(hours > 0 ? hours : nil)
            let projects = appState.timing.projectTotals.map {
                WeeklyProjectShare(title: $0.title, color: $0.color, hours: $0.hours)
            }
            CPUStreamStore.shared.setWeeklyProjects(projects)
        } else {
            CPUStreamStore.shared.setWeeklyHours(nil)
            CPUStreamStore.shared.setWeeklyProjects(nil)
        }
    }

    private func pollOne(host: HostConfig, appState: AppState, timestamp: TimeInterval) {
        // For remote hosts: only poll if the pair's active connection is
        // alive. Spinning up a fresh master here would mean the
        // screensaver background path could trigger SSH auth prompts —
        // emphatically not what we want.
        if !host.isLocal {
            guard appState.sshMuxAlive(for: host) else { return }
        }

        // The stats call takes a channel slot and gives it straight back.
        // It is NOT held across the AMD probe below: a host only allows
        // two concurrent utility channels, and holding one while asking
        // for another means the probe loses every race against whatever
        // else is polling that host — silently, and only on busy hosts.
        guard let output = runStats(host: host, appState: appState) else { return }

        guard let sample = MonitorManager.parse(output: output),
              let cpu = sample.cpuUsage else { return }

        // nvidia and Apple GPUs come back in the stats output above; an
        // AMD card is invisible to it and needs its own probe, so fall
        // back to the most recent reading from that.
        let gpu = sample.gpuUsage
            ?? amdGPU(for: host, isLinux: sample.isLinux, appState: appState)

        CPUStreamStore.shared.appendSample(
            hostID: host.id.uuidString,
            label: Self.label(for: host),
            color: Self.color(for: host),
            cpu: cpu,
            gpu: gpu,
            mem: sample.memUsed,
            memTotal: sample.memTotal,
            timestamp: timestamp
        )

        let containers = Self.parseContainers(in: output)
        let active = self.filterByActivity(containers,
                                           hostID: host.id.uuidString)
        CPUStreamStore.shared.setContainers(
            hostID: host.id.uuidString,
            containers: active.isEmpty ? nil : active
        )
    }

    /// One stats sweep of a host, channel slot acquired and released
    /// within the call.
    private func runStats(host: HostConfig, appState: AppState) -> String? {
        // Channel budget: dedup + per-host cap. If this host's previous
        // fleet poll hasn't returned yet, skip the cycle — don't stack
        // overlapping ssh calls on a slow network.
        guard let releaseChannel = appState.acquireUtilityChannel(
            "fleetPoller:\(host.id)", host: host) else { return nil }
        defer { releaseChannel() }

        let (cmd, args, stdinScript) = appState.statsCommand(host: host)

        // Route through the central executor — bounded with SIGKILL
        // escalation, PID tracked in the unified registry.
        let result = RemoteExec.shared.run(
            cmd, args: args, stdin: stdinScript,
            softTimeout: Self.perHostTimeout,
            captureStdout: true,
            captureStderr: true,
            label: "fleetPoller:\(host.label)"
        )
        return (result.stdout + result.stderr)
            .replacingOccurrences(of: "\r", with: "")
    }

    // MARK: - AMD GPU

    /// The AMD GPU reading for this host: probe if one is due, then
    /// return the freshest cached value.
    ///
    /// Returns nil for non-Linux hosts (a Mac can't answer a line of the
    /// amdgpu probe) and for a host whose last reading has gone stale —
    /// blank is the honest answer there, not a frozen number.
    private func amdGPU(for host: HostConfig, isLinux: Bool,
                        appState: AppState) -> Double? {
        guard isLinux else { return nil }
        let key = host.id.uuidString

        stateLock.lock()
        let due = lastAcceleratorProbe[key].map {
            Date().timeIntervalSince($0) >= Self.acceleratorInterval
        } ?? true
        if due { lastAcceleratorProbe[key] = Date() }   // claim before the call
        stateLock.unlock()

        if due, let value = probeAMDGPU(host: host, appState: appState) {
            stateLock.lock()
            lastAMDGPU[key] = (value, Date())
            stateLock.unlock()
            return value
        }

        stateLock.lock()
        let cached = lastAMDGPU[key]
        stateLock.unlock()
        guard let cached,
              Date().timeIntervalSince(cached.at) < Self.acceleratorStaleAfter else {
            return nil
        }
        return cached.value
    }

    /// One amdgpu sysfs read. Runs on the fleet queue we're already on —
    /// pollOne is off the main thread — and takes its own channel slot so
    /// it obeys the same in-flight dedup and per-host cap as everything
    /// else that touches a host.
    private func probeAMDGPU(host: HostConfig, appState: AppState) -> Double? {
        guard let release = appState.acquireUtilityChannel(
            "fleetAccel:\(host.id)", host: host) else { return nil }
        defer { release() }

        let (cmd, args, stdinScript) = appState.acceleratorCommand(.amdGPU, host: host)
        let result = RemoteExec.shared.run(
            cmd, args: args, stdin: stdinScript,
            softTimeout: Self.perHostTimeout,
            captureStdout: true, captureStderr: true,
            label: "fleetAccel:\(host.label)")
        let output = (result.stdout + result.stderr)
            .replacingOccurrences(of: "\r", with: "")
        return MonitorManager.parse(output: output)?.gpuUsage
    }

    // MARK: - Label / color derivation

    private static func label(for host: HostConfig) -> String {
        if host.isLocal { return "localhost" }
        return host.label.isEmpty ? host.ssh.host : host.label
    }

    /// Deterministic hex color per host. We hash the host UUID into one of a
    /// fixed palette so reruns of the screensaver always tint the same host
    /// the same way. The palette is hand-picked for legibility on the saver's
    /// black background.
    private static let palette: [String] = [
        "FF8C42", // amber
        "22DDFF", // cyan
        "88FF66", // lime
        "FF66CC", // magenta
        "FFD24A", // gold
        "8AB4FF", // periwinkle
        "FF6B6B", // coral
        "B388FF"  // violet
    ]

    /// Filter the latest container list against the rolling activity
    /// record: drop any container that hasn't crossed the activity
    /// threshold within the activity window. Stamps a new "last active"
    /// time whenever a container hits the threshold, then prunes stale
    /// entries to bound memory.
    func filterByActivity(_ containers: [ContainerStream],
                          hostID: String) -> [ContainerStream] {
        let now = Date()
        stateLock.lock()
        defer { stateLock.unlock() }

        var result: [ContainerStream] = []
        for c in containers {
            let key = "\(hostID):\(c.name)"
            if c.cpu >= Self.containerActivityThreshold {
                lastContainerActivity[key] = now
                result.append(c)
            } else if let last = lastContainerActivity[key],
                      now.timeIntervalSince(last) < Self.containerActivityWindow {
                result.append(c)
            }
        }

        // Prune anything older than 2× the visibility window so the
        // dict can't grow unboundedly across a long session.
        let cutoff = now.addingTimeInterval(-Self.containerActivityWindow * 2)
        lastContainerActivity = lastContainerActivity.filter { $0.value > cutoff }
        return result
    }

    /// Test hook — clear the activity record so unit tests start clean.
    func resetActivityForTesting() {
        stateLock.lock()
        lastContainerActivity.removeAll()
        stateLock.unlock()
    }

    /// Extract the `---DOCKER---` section from a stats output and parse
    /// the `name|cpu%` lines into ContainerStream values. Uses
    /// last-occurrence semantics (same as MonitorManager.parse) for
    /// resilience to TTY-echoed script source. Container names are
    /// validated to reject script fragments.
    static func parseContainers(in output: String) -> [ContainerStream] {
        let cleaned = RemoteScript.cleanedOutput(output)
        let sections = cleaned.components(separatedBy: "---")
        var dockerBody = ""
        for i in stride(from: 0, to: sections.count, by: 1) {
            let name = sections[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "DOCKER", i + 1 < sections.count {
                dockerBody = sections[i + 1]  // last occurrence wins
            }
        }
        var result: [ContainerStream] = []
        for raw in dockerBody.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard DockerStatsManager.isValidContainerName(name) else { continue }
            let cpuStr = parts[1]
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let cpu = Double(cpuStr) else { continue }
            result.append(ContainerStream(name: name, cpu: cpu))
        }
        return result
    }

    static func color(for host: HostConfig) -> String {
        let bytes = withUnsafeBytes(of: host.id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        let idx = abs(sum) % palette.count
        return "#" + palette[idx]
    }
}
