//
// DockerStats.swift
//
// Responsibility: Polls `docker stats` on the active host every 5s and
//                 publishes per-container CPU/mem/net/block/pid metrics, with
//                 a rolling 5-minute activity window for visibility filtering.
// Scope: Per-window (DockerStatsManager lives on AppState).
// Threading: Background poll on DispatchQueue.global(.utility); results
//            dispatched to main. A 10s kill timer guards against hung ssh.
// Invariants:
//   - lastActiveTime[name] is updated only when CPU% >= 1.0
//   - visibleContainers respects the 5-minute window unless showAllContainers
//   - lastActiveTime is pruned to entries newer than 2× visibilityWindow
//   - Successful polls feed NetworkTopologyStore.confirmContainersAlive
//
// See: ADR-004 (per-host isolation)
//

import Foundation

// MARK: - Docker Stats

/// DockerContainerStats.
public struct DockerContainerStats: Identifiable {
    /// Id.
    public let id: String // container name
    /// Name.
    public let name: String
    /// Cpu.
    public let cpu: String
    /// Mem usage.
    public let memUsage: String
    /// Net io.
    public let netIO: String
    /// Block io.
    public let blockIO: String
    /// Pids.
    public let pids: String
    /// Uptime, e.g. "2h", "5d". Empty if unknown.
    public let uptime: String

    public init(id: String, name: String, cpu: String, memUsage: String,
                netIO: String, blockIO: String, pids: String, uptime: String = "") {
        self.id = id; self.name = name; self.cpu = cpu; self.memUsage = memUsage
        self.netIO = netIO; self.blockIO = blockIO; self.pids = pids; self.uptime = uptime
    }
}

/// DockerStatsManager.
public class DockerStatsManager: ObservableObject {
    @Published public var containers: [DockerContainerStats] = []
    @Published public var isAvailable = false
    @Published public var cpuCores: Int = 1
    @Published public var showAllContainers = false

    /// Per-container CPU history: name → array of (timestamp, cpuPct) pairs.
    /// Persists across overlay open/close since DockerStatsManager lives on AppState.
    private var cpuHistory: [String: [(Date, Double)]] = [:]

    /// Per-container recent peak CPU: name → timestamp of last sample >= 1% CPU.
    /// Container is visible if it exceeded 1% within the visibility window.
    private var lastActiveTime: [String: Date] = [:]
    /// How long a container stays visible after its last >=1% CPU sample
    private let visibilityWindow: TimeInterval = 300 // 5 minutes

    private var timer: Timer?
    private let appState: AppState

    /// Create a new instance.
    public init(appState: AppState) {
        self.appState = appState
    }

    /// Whether a container should be shown (had >=1% CPU recently)
    private func isContainerActive(_ name: String) -> Bool {
        guard let lastActive = lastActiveTime[name] else { return false }
        return Date().timeIntervalSince(lastActive) < visibilityWindow
    }

    /// Visible containers (filtered or all)
    public var visibleContainers: [DockerContainerStats] {
        guard !showAllContainers else { return containers }
        return containers.filter { isContainerActive($0.name) }
    }

    /// Count of hidden idle containers
    public var hiddenIdleCount: Int {
        guard !showAllContainers else { return 0 }
        return containers.filter { !isContainerActive($0.name) }.count
    }

    /// Start polling.
    public func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Stop polling.
    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        // Two docker calls in one ssh round-trip:
        // - `docker stats` for live CPU/mem/io/pids
        // - `docker ps` for the Status field which contains uptime
        //   ("Up 2 hours", "Up 5 minutes (healthy)", etc).
        // Each line is tagged STAT|... or PS|... so the parser can join
        // them by container name.
        let script = """
        echo CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1); \
        docker stats --no-stream --format "STAT|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}" 2>/dev/null; \
        docker ps --format "PS|{{.Names}}|{{.Status}}" 2>/dev/null
        """
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()

                let killTimer = DispatchSource.makeTimerSource(queue: .global())
                killTimer.schedule(deadline: .now() + 10)
                killTimer.setEventHandler { if process.isRunning { process.terminate() } }
                killTimer.resume()

                process.waitUntilExit()
                killTimer.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                let (cores, parsed) = Self.parse(output: output)

                // Feed alive containers into topology store
                if !parsed.isEmpty, let hostID = self?.appState.activeHost?.id {
                    let names = parsed.map(\.name)
                    NetworkTopologyStore.shared.confirmContainersAlive(hostID: hostID, containerNames: names)
                }

                DispatchQueue.main.async {
                    self?.cpuCores = cores
                    self?.containers = parsed
                    self?.isAvailable = !parsed.isEmpty

                    // Track per-container CPU activity
                    let now = Date()
                    for container in parsed {
                        let pct = Self.parseCPUPct(container.cpu)
                        if pct >= 1.0 {
                            self?.lastActiveTime[container.name] = now
                        }
                    }
                    // Prune containers not seen in a while
                    let cutoff = now.addingTimeInterval(-(self?.visibilityWindow ?? 300) * 2)
                    self?.lastActiveTime = self?.lastActiveTime.filter { $0.value > cutoff } ?? [:]
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAvailable = false
                }
            }
        }
    }

    /// Parse "12.34%" → 12.34
    static func parseCPUPct(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) ?? 0
    }

    /// Parse.
    public static func parse(output: String) -> (cores: Int, containers: [DockerContainerStats]) {
        var cores = 1
        var uptimeByName: [String: String] = [:]
        var statRows: [(name: String, cpu: String, mem: String, net: String, block: String, pids: String)] = []

        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("CORES=") {
                cores = Int(line.dropFirst(6)) ?? 1
                continue
            }
            let parts = line.components(separatedBy: "|")
            if parts.first == "PS", parts.count >= 3 {
                uptimeByName[parts[1]] = compactUptime(from: parts[2])
            } else if parts.first == "STAT", parts.count >= 7 {
                statRows.append((parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]))
            } else if parts.count >= 6 {
                // Backwards-compat: lines without the STAT/PS tag (older
                // format used in tests and for fallback)
                statRows.append((parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]))
            }
        }

        let containers = statRows.map { row in
            DockerContainerStats(
                id: row.name, name: row.name,
                cpu: row.cpu, memUsage: row.mem, netIO: row.net,
                blockIO: row.block, pids: row.pids,
                uptime: uptimeByName[row.name] ?? ""
            )
        }
        return (cores, containers)
    }

    /// Turn a docker `Status` field ("Up 2 hours", "Up 5 minutes (healthy)",
    /// "Up 3 days", "Up About a minute") into a compact "2h" / "5m" / "3d"
    /// suitable for a narrow table column. Non-Up statuses pass through.
    static func compactUptime(from status: String) -> String {
        let s = status.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("Up ") else { return s }
        // Strip "Up " and any trailing health annotation in parens
        var rest = String(s.dropFirst(3))
        if let paren = rest.range(of: " (") { rest = String(rest[..<paren.lowerBound]) }
        rest = rest.trimmingCharacters(in: .whitespaces)

        // Numeric forms first: "2 hours", "5 minutes", "3 days", "1 week"
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let n = Int(parts[0]) {
            let unit = parts[1].lowercased()
            if unit.hasPrefix("second") { return "\(n)s" }
            if unit.hasPrefix("minute") { return "\(n)m" }
            if unit.hasPrefix("hour")   { return "\(n)h" }
            if unit.hasPrefix("day")    { return "\(n)d" }
            if unit.hasPrefix("week")   { return "\(n)w" }
            if unit.hasPrefix("month")  { return "\(n)mo" }
            if unit.hasPrefix("year")   { return "\(n)y" }
            return rest
        }

        // Word forms: "Less than a second", "About a minute", "About an hour"
        let lower = rest.lowercased()
        if lower.contains("less than") && lower.contains("second") { return "<1s" }
        if lower.hasPrefix("about a minute") || lower == "a minute" { return "1m" }
        if lower.hasPrefix("about an hour") || lower == "an hour" { return "1h" }
        return rest
    }

}
