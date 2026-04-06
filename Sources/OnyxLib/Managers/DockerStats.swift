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

public struct DockerContainerStats: Identifiable {
    public let id: String // container name
    public let name: String
    public let cpu: String
    public let memUsage: String
    public let netIO: String
    public let blockIO: String
    public let pids: String
}

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

    public func startPolling() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let script = "echo CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1); docker stats --no-stream --format \"{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}\" 2>/dev/null"
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

    public static func parse(output: String) -> (cores: Int, containers: [DockerContainerStats]) {
        var cores = 1
        let containers = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line -> DockerContainerStats? in
                // Parse CORES=N line
                if line.hasPrefix("CORES=") {
                    cores = Int(line.dropFirst(6)) ?? 1
                    return nil
                }
                let parts = line.components(separatedBy: "|")
                guard parts.count >= 6 else { return nil }
                return DockerContainerStats(
                    id: parts[0],
                    name: parts[0],
                    cpu: parts[1],
                    memUsage: parts[2],
                    netIO: parts[3],
                    blockIO: parts[4],
                    pids: parts[5]
                )
            }
        return (cores, containers)
    }
}
