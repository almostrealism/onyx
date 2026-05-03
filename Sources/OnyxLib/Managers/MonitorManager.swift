//
// MonitorManager.swift
//
// Responsibility: Polls system metrics (CPU, mem, GPU, etc) on the active
//                 host every 5s and maintains a per-host rolling sample
//                 buffer for charts and the status pill.
// Scope: Per-window (lives on AppState); state is partitioned per host UUID.
// Threading: Timer fires on main; sample collection shells out on a background
//            queue and dispatches back to main to mutate hostData.
// Invariants:
//   - hostData is keyed by host UUID; reads for the active host fall back to
//     an empty HostMonitorData if missing
//   - Each host's samples array is capped at maxSamples (720 ≈ 1h @ 5s)
//   - Switching the active host does NOT clear other hosts' buffers
//   - isPolling is true iff `timer` is non-nil
//
// See: ADR-004 (per-host isolation)
//

import Foundation
import Combine

/// MonitorManager.
public class MonitorManager: ObservableObject {
    @Published public var isPolling = false
    @Published public var showMemoryChart = false
    @Published public var pollCount = 0
    @Published public var useShortInterval = true

    /// Per-host data storage
    private var hostData: [UUID: HostMonitorData] = [:]

    /// Data for the active host (computed from hostData)
    public var samples: [MonitorSample] { activeHostData.samples }
    /// Latest sample.
    public var latestSample: MonitorSample? { activeHostData.latestSample }
    /// Gpu ever seen.
    public var gpuEverSeen: Bool { activeHostData.gpuEverSeen }
    /// Last error.
    public var lastError: String? { activeHostData.lastError }
    /// Diagnostic explaining why the CPU chart can't render. Set when parse
    /// returned a sample but its cpuUsage was nil (i.e. the remote's top
    /// output didn't match any recognized format). Cleared on next success.
    public var cpuDiagnostic: String? { activeHostData.cpuParseFailureReason }

    private var timer: Timer?
    private let appState: AppState
    private let maxSamples = 720

    /// Active host's data (or creates empty)
    private var activeHostData: HostMonitorData {
        let id = appState.activeHost?.id ?? HostConfig.localhostID
        return hostData[id] ?? HostMonitorData()
    }

    /// Inject samples for testing (sets data for the active host)
    public func injectSamples(_ samples: [MonitorSample]) {
        let id = appState.activeHost?.id ?? HostConfig.localhostID
        var data = hostData[id] ?? HostMonitorData()
        data.samples = samples
        data.latestSample = samples.last
        hostData[id] = data
    }

    private struct HostMonitorData {
        var samples: [MonitorSample] = []
        var latestSample: MonitorSample?
        var gpuEverSeen = false
        var consecutiveGpuMisses = 0
        var lastError: String?
        var cpuParseFailureReason: String?
    }

    /// Create a new instance.
    public init(appState: AppState) {
        self.appState = appState
    }

    /// Start polling.
    public func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        poll() // immediate first poll
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Stop polling.
    public func stopPolling() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }

    /// Toggle interval.
    public func toggleInterval() {
        useShortInterval.toggle()
    }

    /// Get bucketed values for the grid chart. Returns up to 60 buckets.
    public func bucketedCPU() -> [Double] {
        return bucket(samples.map { ($0.timestamp, $0.cpuUsage) }, for: "cpu")
    }

    /// Bucketed memory.
    public func bucketedMemory() -> [Double] {
        return bucket(samples.map { s -> (Date, Double?) in
            guard let u = s.memUsed, let t = s.memTotal, t > 0 else { return (s.timestamp, nil) }
            return (s.timestamp, (u / t) * 100)
        }, for: "mem")
    }

    /// Bucketed gpu.
    public func bucketedGPU() -> [Double] {
        let data = bucket(samples.map { ($0.timestamp, $0.gpuUsage) }, for: "gpu")
        // If GPU was ever seen but current data is empty (transient failure),
        // return zeros to keep the chart visible
        if data.isEmpty && gpuEverSeen {
            return Array(repeating: 0.0, count: 60)
        }
        return data
    }

    private func bucket(_ data: [(Date, Double?)], for label: String) -> [Double] {
        let hasAny = data.contains { $0.1 != nil }
        guard hasAny else { return [] }
        let bucketCount = 60

        if useShortInterval {
            // 5s polling ≈ 1 sample per column — use values directly to avoid
            // timer-jitter gaps from time-based bucketing.
            // Use 0 for missing values to keep all charts aligned.
            let recent = data.suffix(bucketCount).map { $0.1 ?? 0 }
            let padding = Array(repeating: 0.0, count: max(0, bucketCount - recent.count))
            return padding + recent
        }

        // 1-minute buckets: anchor to wall-clock minutes so bars don't shift.
        // Each bar represents a fixed minute (e.g., 14:03, 14:04, ...).
        // Only the current (rightmost) bar changes as new samples arrive.
        let interval: TimeInterval = 60
        let now = Date()
        // Round "now" down to the start of the current minute
        let calendar = Calendar.current
        let currentMinuteStart = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now))!
        // The rightmost bucket covers [currentMinuteStart, currentMinuteStart+60)
        // The leftmost bucket covers [currentMinuteStart - 59*60, currentMinuteStart - 58*60)
        var buckets: [Double] = Array(repeating: -1, count: bucketCount)

        for i in 0..<bucketCount {
            // i=0 is oldest, i=59 is current minute
            let minuteOffset = bucketCount - 1 - i
            let bucketStart = currentMinuteStart.addingTimeInterval(-Double(minuteOffset) * interval)
            let bucketEnd = bucketStart.addingTimeInterval(interval)
            let vals = data.filter { $0.0 >= bucketStart && $0.0 < bucketEnd }.compactMap { $0.1 }
            if !vals.isEmpty {
                buckets[i] = vals.reduce(0, +) / Double(vals.count)
            }
        }

        return buckets.map { $0 < 0 ? 0 : $0 }
    }

    private func poll() {
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        let (cmd, args) = appState.statsCommand()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()

                let killTimer = DispatchSource.makeTimerSource(queue: .global())
                killTimer.schedule(deadline: .now() + 10)
                killTimer.setEventHandler {
                    if process.isRunning { process.terminate() }
                }
                killTimer.resume()

                process.waitUntilExit()
                killTimer.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                DispatchQueue.main.async { self?.pollCount += 1 }

                // Exit code 255 = SSH connection failed; other non-zero may just
                // mean the stats script had a partial failure (GPU check, etc.)
                // Still try to parse output even on non-zero exit codes.
                if process.terminationStatus == 255 {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        var data = self.hostData[hostID] ?? HostMonitorData()
                        data.lastError = "SSH connection failed (code 255)"
                        self.hostData[hostID] = data
                        self.objectWillChange.send()
                    }
                    return
                }
                guard !output.isEmpty else {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        var data = self.hostData[hostID] ?? HostMonitorData()
                        data.lastError = "Empty response from remote"
                        self.hostData[hostID] = data
                        self.objectWillChange.send()
                    }
                    return
                }

                if let sample = Self.parse(output: output) {
                    let cpuDiag = sample.cpuUsage == nil ? Self.cpuDiagnostic(from: output) : nil
                    DispatchQueue.main.async {
                        guard let self = self else { return }

                        // Store sample in per-host data — clear any previous error
                        var data = self.hostData[hostID] ?? HostMonitorData()
                        data.lastError = nil
                        data.latestSample = sample
                        data.samples.append(sample)
                        if data.samples.count > self.maxSamples {
                            data.samples.removeFirst(data.samples.count - self.maxSamples)
                        }
                        if sample.gpuUsage != nil {
                            data.gpuEverSeen = true
                            data.consecutiveGpuMisses = 0
                        } else if data.gpuEverSeen {
                            data.consecutiveGpuMisses += 1
                            if data.consecutiveGpuMisses >= 60 {
                                data.gpuEverSeen = false
                            }
                        }
                        data.cpuParseFailureReason = cpuDiag
                        self.hostData[hostID] = data
                        self.objectWillChange.send()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    var data = self.hostData[hostID] ?? HostMonitorData()
                    data.lastError = "Failed to run ssh: \(error.localizedDescription)"
                    self.hostData[hostID] = data
                    self.objectWillChange.send()
                }
            }
        }
    }

    /// Parse a size string like "127G", "121M", "4096K" into MB
    public static func parseSizeMB(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("G") || trimmed.hasSuffix("g") {
            return Double(trimmed.dropLast()).map { $0 * 1024 }
        } else if trimmed.hasSuffix("M") || trimmed.hasSuffix("m") {
            return Double(trimmed.dropLast())
        } else if trimmed.hasSuffix("K") || trimmed.hasSuffix("k") {
            return Double(trimmed.dropLast()).map { $0 / 1024 }
        }
        return Double(trimmed)
    }

    /// Try to parse PhysMem from a line, returns (used, total) in MB
    private static func parsePhysMem(_ line: String) -> (Double, Double)? {
        guard line.contains("PhysMem:") else { return nil }
        let usedPattern = #"(\d+\w?)\s+used"#
        let unusedPattern = #"(\d+\w?)\s+unused"#
        var used: Double?
        var total: Double?
        if let regex = try? NSRegularExpression(pattern: usedPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(match.range(at: 1), in: line) {
            used = parseSizeMB(String(line[r]))
        }
        if let usedVal = used,
           let regex = try? NSRegularExpression(pattern: unusedPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let r = Range(match.range(at: 1), in: line) {
            if let unused = parseSizeMB(String(line[r])) {
                total = usedVal + unused
            }
        }
        if let u = used, let t = total {
            return (u, t)
        }
        return nil
    }

    /// Parse.
    /// Scan the given lines for any recognized `top` CPU-summary format and
    /// return the computed CPU usage % (100 - idle). Returns nil if none
    /// match. Lifted out of `parse` so we can run it on a section's lines and
    /// fall back to running it on the entire output when section parsing
    /// gets contaminated (e.g. by `set -v` echoes from the remote profile).
    ///
    /// Handles all known variants in one permissive pattern:
    ///   - macOS top -l1: "CPU usage: 19.46% user, 7.6% sys, 73.47% idle"
    ///   - Linux top -bn1: "%Cpu(s):  2.3 us, ... 96.7 id"
    ///   - Linux alt:      "Cpu(s):  3.5%us, ... 95.3%id"
    ///   - BusyBox top:    "CPU: 3% usr  1% sys  0% nic  96% idle ..."
    /// The line must mention "cpu" (case-insensitive) to filter false matches.
    public static func scanCpuUsage(in lines: [String]) -> Double? {
        let idlePattern = #"(\d+\.?\d*)\s*%?\s*id(le)?\b"#
        guard let regex = try? NSRegularExpression(pattern: idlePattern) else { return nil }
        for line in lines {
            guard line.lowercased().contains("cpu") else { continue }
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(match.range(at: 1), in: line),
               let idle = Double(line[r]) {
                return 100.0 - idle
            }
        }
        return nil
    }

    /// Diagnose why CPU usage couldn't be extracted from `output`. Returns a
    /// short, user-facing message describing the failure mode. Only meaningful
    /// when called after a successful parse with `cpuUsage == nil`.
    ///
    /// First checks for the `---SCRIPT-OK---` execution proof — if missing,
    /// the script never ran on the remote (most likely the login shell has a
    /// `set -n` / dry-run mode enabled in its profile, or refuses to execute
    /// our `-c` argument). Otherwise reports on the *last* CPU section seen
    /// (when verbose mode is on, the script source's `---CPU---` is echoed
    /// before the real one and the actual top output lands in the last
    /// section).
    public static func cpuDiagnostic(from output: String) -> String {
        if !output.contains("---SCRIPT-OK---") {
            return "Stats script did not execute on the remote — only its source came back. The remote login shell is likely refusing to run `-c` commands (e.g. it has `set -n` or a similar dry-run mode in its profile)."
        }
        let sections = output.components(separatedBy: "---")
        var cpuSections: [String] = []
        for i in stride(from: 0, to: sections.count, by: 1) {
            let section = sections[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if section == "CPU", i + 1 < sections.count {
                cpuSections.append(sections[i + 1])
            }
        }
        guard let last = cpuSections.last else {
            return "Stats output has no CPU section. The remote may be missing 'top'."
        }
        let lines = last.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty {
            return "CPU section was empty — 'top' produced no output."
        }
        let joined = lines.prefix(3).joined(separator: " | ")
        let cap = 140
        let snippet = joined.count > cap ? String(joined.prefix(cap)) + "…" : joined
        let countNote = cpuSections.count > 1 ? " (\(cpuSections.count) sections seen)" : ""
        return "Unrecognized 'top' output\(countNote). Sample: \(snippet)"
    }

    public static func parse(output: String) -> MonitorSample? {
        let sections = output.components(separatedBy: "---")
        var loadAvg1: Double?, loadAvg5: Double?, loadAvg15: Double?
        var cpuUsage: Double?
        var memUsed: Double?, memTotal: Double?
        var gpuUsage: Double?, gpuMemUsage: Double?, gpuTemp: Int?, gpuName: String?

        for i in stride(from: 0, to: sections.count, by: 1) {
            let section = sections[i].trimmingCharacters(in: .whitespacesAndNewlines)

            if section == "UPTIME", i + 1 < sections.count {
                let uptimeStr = sections[i + 1]
                if let loadRange = uptimeStr.range(of: "load average: ") ?? uptimeStr.range(of: "load averages: ") {
                    let loadStr = String(uptimeStr[loadRange.upperBound...])
                    let parts = loadStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if parts.count >= 3 {
                        loadAvg1 = Double(parts[0])
                        loadAvg5 = Double(parts[1])
                        loadAvg15 = Double(parts[2])
                    }
                }
            }

            if section == "CPU", i + 1 < sections.count {
                let cpuStr = sections[i + 1]
                let lines = cpuStr.components(separatedBy: "\n")
                if cpuUsage == nil { cpuUsage = scanCpuUsage(in: lines) }
                for line in lines {
                    // macOS top also outputs PhysMem line — grab memory from here
                    if memUsed == nil, let phys = parsePhysMem(line) {
                        memUsed = phys.0
                        memTotal = phys.1
                    }
                }
            }

            if section == "MEM", i + 1 < sections.count {
                let memStr = sections[i + 1]
                let lines = memStr.components(separatedBy: "\n")
                for line in lines {
                    // Linux free -m: "Mem:  total  used  free ..."
                    if line.hasPrefix("Mem:") {
                        let parts = line.split(separator: " ").map(String.init)
                        if parts.count >= 3 {
                            memTotal = Double(parts[1])
                            memUsed = Double(parts[2])
                        }
                    }
                    // macOS: "PhysMem: 127G used ..."
                    if memUsed == nil, let phys = parsePhysMem(line) {
                        memUsed = phys.0
                        memTotal = phys.1
                    }
                }
            }

            if section == "GPU", i + 1 < sections.count {
                let gpuStr = sections[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if gpuStr != "N/A" && !gpuStr.isEmpty {
                    let parts = gpuStr.components(separatedBy: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: " %", with: "")
                    }
                    if parts.count >= 4, Double(parts[0]) != nil {
                        // nvidia-smi format: "usage%, memUsage%, temp, name"
                        gpuUsage = Double(parts[0])
                        gpuMemUsage = Double(parts[1])
                        gpuTemp = Int(parts[2])
                        gpuName = parts[3]
                    } else if parts.count == 2, let pct = Double(parts[1]) {
                        // Apple Silicon format: "AGX,42"
                        gpuName = parts[0]
                        gpuUsage = pct
                    }
                }
            }
        }

        // Fallback: if the CPU section was contaminated (e.g. by a remote
        // shell echoing script source via `set -v`) and we didn't pick up
        // a usage value, scan the entire output. The actual `top` line will
        // still be in there somewhere even if it's not where we expected.
        if cpuUsage == nil {
            cpuUsage = scanCpuUsage(in: output.components(separatedBy: "\n"))
        }

        return MonitorSample(
            timestamp: Date(),
            cpuUsage: cpuUsage,
            memUsed: memUsed,
            memTotal: memTotal,
            gpuUsage: gpuUsage,
            gpuMemUsage: gpuMemUsage,
            gpuTemp: gpuTemp,
            gpuName: gpuName,
            loadAvg1: loadAvg1,
            loadAvg5: loadAvg5,
            loadAvg15: loadAvg15
        )
    }
}
