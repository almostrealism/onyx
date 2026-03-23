import SwiftUI
import EventKit

public struct MonitorSample: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public var cpuUsage: Double?     // 0-100, nil if unparseable
    public var memUsed: Double?      // MB
    public var memTotal: Double?     // MB
    public var gpuUsage: Double?     // 0-100
    public var gpuMemUsage: Double?  // 0-100
    public var gpuTemp: Int?
    public var gpuName: String?
    public var loadAvg1: Double?
    public var loadAvg5: Double?
    public var loadAvg15: Double?

    public init(timestamp: Date, cpuUsage: Double? = nil, memUsed: Double? = nil, memTotal: Double? = nil, gpuUsage: Double? = nil, gpuMemUsage: Double? = nil, gpuTemp: Int? = nil, gpuName: String? = nil, loadAvg1: Double? = nil, loadAvg5: Double? = nil, loadAvg15: Double? = nil) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.gpuUsage = gpuUsage
        self.gpuMemUsage = gpuMemUsage
        self.gpuTemp = gpuTemp
        self.gpuName = gpuName
        self.loadAvg1 = loadAvg1
        self.loadAvg5 = loadAvg5
        self.loadAvg15 = loadAvg15
    }
}

public class MonitorManager: ObservableObject {
    @Published public var samples: [MonitorSample] = []
    @Published public var latestSample: MonitorSample?
    @Published public var isPolling = false
    @Published public var lastError: String?
    @Published public var showMemoryChart = false
    @Published public var pollCount = 0
    @Published public var useShortInterval = true // true = 5s buckets (default), false = 1m buckets
    /// True once any sample has ever contained GPU data — prevents chart from vanishing on transient failures
    @Published public var gpuEverSeen = false

    private var timer: Timer?
    private let appState: AppState
    private let maxSamples = 720 // 1 hour at 5s intervals
    /// Count of consecutive GPU-less polls (to detect persistent loss)
    private var consecutiveGpuMisses = 0
    private let gpuMissThreshold = 60  // after 60 misses (5 min at 5s) consider GPU truly gone

    public init(appState: AppState) {
        self.appState = appState
    }

    public func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        poll() // immediate first poll
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stopPolling() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }

    public func toggleInterval() {
        useShortInterval.toggle()
    }

    /// Get bucketed values for the grid chart. Returns up to 60 buckets.
    public func bucketedCPU() -> [Double] {
        return bucket(samples.map { ($0.timestamp, $0.cpuUsage) }, for: "cpu")
    }

    public func bucketedMemory() -> [Double] {
        return bucket(samples.map { s -> (Date, Double?) in
            guard let u = s.memUsed, let t = s.memTotal, t > 0 else { return (s.timestamp, nil) }
            return (s.timestamp, (u / t) * 100)
        }, for: "mem")
    }

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

        // 1-minute buckets: aggregate multiple 5s samples
        let interval: TimeInterval = 60
        let now = Date()
        var buckets: [Double] = Array(repeating: -1, count: bucketCount)

        for i in 0..<bucketCount {
            let bucketEnd = now.addingTimeInterval(-Double(i) * interval)
            let bucketStart = bucketEnd.addingTimeInterval(-interval)
            let vals = data.filter { $0.0 > bucketStart && $0.0 <= bucketEnd }.compactMap { $0.1 }
            if !vals.isEmpty {
                buckets[bucketCount - 1 - i] = vals.reduce(0, +) / Double(vals.count)
            }
        }

        return buckets.map { $0 < 0 ? 0 : $0 }
    }

    private func poll() {
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

                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async {
                        self?.lastError = "SSH exited with code \(process.terminationStatus). Check that key-based auth works for this host."
                    }
                    return
                }
                guard !output.isEmpty else {
                    DispatchQueue.main.async { self?.lastError = "Empty response from remote" }
                    return
                }

                if let sample = Self.parse(output: output) {
                    DispatchQueue.main.async {
                        self?.lastError = nil
                        self?.latestSample = sample
                        self?.samples.append(sample)
                        if let count = self?.samples.count, count > (self?.maxSamples ?? 720) {
                            self?.samples.removeFirst(count - (self?.maxSamples ?? 720))
                        }
                        // Track GPU presence: once seen, keep showing until
                        // many consecutive polls come back without GPU data
                        if sample.gpuUsage != nil {
                            self?.gpuEverSeen = true
                            self?.consecutiveGpuMisses = 0
                        } else if self?.gpuEverSeen == true {
                            self?.consecutiveGpuMisses += 1
                            if let misses = self?.consecutiveGpuMisses,
                               misses >= (self?.gpuMissThreshold ?? 60) {
                                self?.gpuEverSeen = false
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.lastError = "Failed to run ssh: \(error.localizedDescription)"
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
                for line in lines {
                    // macOS: "CPU usage: 19.46% user, 7.6% sys, 73.47% idle"
                    if line.contains("CPU usage:") {
                        let idlePattern = #"(\d+\.?\d*)%\s*idle"#
                        if let regex = try? NSRegularExpression(pattern: idlePattern),
                           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                           let r = Range(match.range(at: 1), in: line) {
                            cpuUsage = (100.0 - (Double(line[r]) ?? 0))
                        }
                    }
                    // Linux: "%Cpu(s):  2.3 us, ... 96.7 id"
                    if line.contains("Cpu(s)") || line.contains("%Cpu") {
                        let idlePattern = #"(\d+\.?\d*)\s*%?\s*id"#
                        if let regex = try? NSRegularExpression(pattern: idlePattern),
                           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                           let r = Range(match.range(at: 1), in: line) {
                            cpuUsage = (100.0 - (Double(line[r]) ?? 0))
                        }
                    }
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

/// A group of reminders under one list name
public struct ReminderListGroup: Identifiable {
    public let id: String   // list name
    public let name: String
    public let reminders: [EKReminder]
}

public class RemindersManager: ObservableObject {
    @Published public var reminders: [EKReminder] = []
    /// Reminders grouped by list, in the order of selectedLists
    @Published public var groupedReminders: [ReminderListGroup] = []
    @Published public var accessGranted = false
    @Published public var availableLists: [String] = []

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var changeObserver: Any?
    public var selectedLists: [String] = []  // empty = "Today" (due today across all lists)

    /// True when showing multiple lists (grouped display)
    public var isMultiList: Bool { selectedLists.count > 1 }

    /// Display name for the header
    public var displayName: String {
        if selectedLists.isEmpty { return "TODAY" }
        if selectedLists.count == 1 { return selectedLists[0].uppercased() }
        return "REMINDERS"
    }

    /// Total count across all groups
    public var totalCount: Int {
        if isMultiList { return groupedReminders.reduce(0) { $0 + $1.reminders.count } }
        return reminders.count
    }

    /// Empty-state message
    public var emptyMessage: String {
        selectedLists.isEmpty ? "No reminders due today" : "No reminders"
    }

    public init() {
        requestAccess()

        // Refresh when reminders change externally (other apps, iCloud sync)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.refreshLists()
            self?.fetchReminders()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = changeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func requestAccess() {
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.accessGranted = granted
                if granted {
                    self?.refreshLists()
                    self?.fetchReminders()
                    self?.startTimer()
                }
            }
        }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchReminders()
        }
    }

    public func refreshLists() {
        let calendars = store.calendars(for: .reminder)
        availableLists = calendars.map(\.title).sorted()
    }

    public func fetchReminders() {
        guard accessGranted else { return }

        if selectedLists.isEmpty {
            // "Today" mode: incomplete reminders due by end of today, across all lists
            fetchTodayReminders(calendars: nil)
        } else if selectedLists.count == 1 {
            // Single list: flat display
            let match = store.calendars(for: .reminder).filter { selectedLists.contains($0.title) }
            if match.isEmpty {
                DispatchQueue.main.async { self.reminders = []; self.groupedReminders = [] }
            } else {
                fetchListReminders(calendars: match)
            }
        } else {
            // Multiple lists: fetch per-list and group
            fetchGroupedReminders()
        }
    }

    private func fetchTodayReminders(calendars: [EKCalendar]?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

            let predicate = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: endOfDay,
                calendars: calendars
            )

            self.store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted { a, b in
                    let da = a.dueDateComponents?.date ?? .distantFuture
                    let db = b.dueDateComponents?.date ?? .distantFuture
                    return da < db
                }
                DispatchQueue.main.async {
                    self.reminders = sorted
                }
            }
        }
    }

    private func fetchListReminders(calendars: [EKCalendar]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let predicate = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )

            self.store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted { a, b in
                    let pa = a.priority
                    let pb = b.priority
                    // Sort by priority (1=high, 5=medium, 9=low, 0=none→last)
                    let normA = pa == 0 ? 100 : pa
                    let normB = pb == 0 ? 100 : pb
                    if normA != normB { return normA < normB }
                    let da = a.dueDateComponents?.date ?? .distantFuture
                    let db = b.dueDateComponents?.date ?? .distantFuture
                    return da < db
                }
                DispatchQueue.main.async {
                    self.reminders = sorted
                }
            }
        }
    }

    private func fetchGroupedReminders() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let allCalendars = self.store.calendars(for: .reminder)
            let listOrder = self.selectedLists
            var groups: [ReminderListGroup] = []

            for listName in listOrder {
                guard let calendar = allCalendars.first(where: { $0.title == listName }) else { continue }
                let predicate = self.store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: [calendar]
                )
                // fetchReminders is async with callback — use a semaphore for sequential fetch
                let sem = DispatchSemaphore(value: 0)
                var fetched: [EKReminder] = []
                self.store.fetchReminders(matching: predicate) { reminders in
                    fetched = (reminders ?? []).sorted { a, b in
                        let normA = a.priority == 0 ? 100 : a.priority
                        let normB = b.priority == 0 ? 100 : b.priority
                        if normA != normB { return normA < normB }
                        let da = a.dueDateComponents?.date ?? .distantFuture
                        let db = b.dueDateComponents?.date ?? .distantFuture
                        return da < db
                    }
                    sem.signal()
                }
                sem.wait()
                groups.append(ReminderListGroup(id: listName, name: listName, reminders: fetched))
            }

            DispatchQueue.main.async {
                self.groupedReminders = groups
                self.reminders = groups.flatMap(\.reminders)
            }
        }
    }

    public func toggleComplete(_ reminder: EKReminder) {
        reminder.isCompleted = !reminder.isCompleted
        try? store.save(reminder, commit: true)
        fetchReminders()
    }
}

private func formatMB(_ mb: Double) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return "\(Int(mb)) MB"
}

struct MonitorView: View {
    @ObservedObject var appState: AppState
    @StateObject private var dockerStats: DockerStatsManager

    init(appState: AppState) {
        self.appState = appState
        _dockerStats = StateObject(wrappedValue: DockerStatsManager(appState: appState))
    }

    private var monitor: MonitorManager { appState.monitor }

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 20) {
                // Current time
                TimeDisplay(accentColor: appState.accentColor)

                Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 40)

                if let sample = monitor.latestSample {
                    // Current values row
                    HStack(spacing: 30) {
                        if let cpu = sample.cpuUsage {
                            StatChip(label: "CPU", value: "\(Int(cpu))%", accentColor: Color(hex: "66CCFF"))
                        }
                        if let used = sample.memUsed, let total = sample.memTotal, total > 0 {
                            StatChip(label: "MEM", value: "\(formatMB(used)) / \(formatMB(total))", accentColor: Color(hex: "FFD06B"))
                        }
                        if let gpu = sample.gpuUsage {
                            StatChip(label: "GPU", value: "\(Int(gpu))%", accentColor: Color(hex: "C06BFF"))
                        }
                        if let temp = sample.gpuTemp {
                            StatChip(label: "TEMP", value: "\(temp)°C", accentColor: Color(hex: "FF6B6B"))
                        }
                    }

                    // Interval label
                    HStack(spacing: 4) {
                        Text(monitor.useShortInterval ? "5s intervals" : "1m intervals")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                        Text("(T interval · M memory)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.25))
                    }
                    .padding(.top, 4)

                    // TOP HALF: Charts + Docker stats side by side
                    HStack(alignment: .top, spacing: 24) {
                        // Charts (left or full width)
                        VStack(spacing: 16) {
                            let cpuData = monitor.bucketedCPU()
                            if !cpuData.isEmpty {
                                GridChart(
                                    title: "CPU",
                                    values: cpuData,
                                    accentColor: Color(hex: "66CCFF")
                                )
                            }

                            // Memory + GPU area: fixed total height, charts share space
                            let memData = monitor.showMemoryChart ? monitor.bucketedMemory() : []
                            let gpuData = monitor.bucketedGPU()
                            let hasMem = !memData.isEmpty && monitor.showMemoryChart
                            let hasGpu = !gpuData.isEmpty
                            let subChartHeight: CGFloat = 100 // total area for mem+gpu

                            if hasMem && hasGpu {
                                // Both: split the space evenly
                                let halfHeight = (subChartHeight - 16) / 2 // 16 = spacing
                                GridChart(
                                    title: "MEMORY",
                                    values: memData,
                                    accentColor: Color(hex: "FFD06B"),
                                    height: halfHeight
                                )
                                GridChart(
                                    title: "GPU",
                                    values: gpuData,
                                    accentColor: Color(hex: "C06BFF"),
                                    height: halfHeight
                                )
                            } else if hasMem {
                                GridChart(
                                    title: "MEMORY",
                                    values: memData,
                                    accentColor: Color(hex: "FFD06B"),
                                    height: subChartHeight
                                )
                            } else if hasGpu {
                                GridChart(
                                    title: "GPU",
                                    values: gpuData,
                                    accentColor: Color(hex: "C06BFF"),
                                    height: subChartHeight
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)

                        // Docker container stats (right half, only if available)
                        if dockerStats.isAvailable {
                            DockerStatsSection(appState: appState, dockerStats: dockerStats)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 40)

                    Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 40)

                    // BOTTOM HALF: Connections + Reminders side by side
                    HStack(alignment: .top, spacing: 24) {
                        ConnectionPoolSection(appState: appState)
                            .frame(maxWidth: .infinity)
                        RemindersSection(appState: appState)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 4)

                } else if let error = monitor.lastError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundColor(Color(hex: "FF6B6B"))
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: "FF6B6B").opacity(0.8))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        Text("Retrying every 5s... (attempt \(monitor.pollCount))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .colorScheme(.dark)
                        Text("Fetching stats from \(appState.activeHost?.label ?? "host")...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                }

                Spacer()
            }
            .padding(.top, 40)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMonitorInterval)) { _ in
            monitor.toggleInterval()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMemoryChart)) { _ in
            monitor.showMemoryChart.toggle()
        }
        .onAppear {
            dockerStats.startPolling()
            // Trigger an immediate pool status publish via notification
            NotificationCenter.default.post(name: .refreshPoolStatus, object: nil)
        }
        .onDisappear {
            dockerStats.stopPolling()
        }
    }
}

struct TimeDisplay: View {
    let accentColor: Color
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            Text(timeString)
                .font(.system(size: 48, weight: .ultraLight, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            Text(dateString)
                .font(.system(size: 14, weight: .light, design: .monospaced))
                .foregroundColor(accentColor.opacity(0.6))
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: currentTime)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: currentTime)
    }
}

struct StatChip: View {
    let label: String
    let value: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(accentColor)
                .tracking(2)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6)
    }
}

/// Activity Monitor-style grid chart: each time bucket is a column of small squares.
/// More squares "lit" = higher usage. Drawn with Canvas to avoid sub-pixel gaps
/// from SwiftUI layout rounding of individual Rectangle views.
struct GridChart: View {
    let title: String
    let values: [Double] // 0-100 per bucket
    let accentColor: Color
    var height: CGFloat = 100
    let rows = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(accentColor)
                .tracking(2)

            Canvas { context, size in
                let cols = values.count
                guard cols > 0 else { return }
                let gap: CGFloat = 1
                let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                guard cellW > 0 && cellH > 0 else { return }

                let dimColor = Color.white.opacity(0.03)

                for col in 0..<cols {
                    let litCount = Int((values[col] / 100.0) * Double(rows))
                    let x = CGFloat(col) * (cellW + gap)

                    for row in 0..<rows {
                        let y = CGFloat(row) * (cellH + gap)
                        let isLit = row >= (rows - litCount)
                        let rect = CGRect(
                            x: x.rounded(.down),
                            y: y.rounded(.down),
                            width: (x + cellW).rounded(.down) - x.rounded(.down),
                            height: (y + cellH).rounded(.down) - y.rounded(.down)
                        )
                        context.fill(
                            Path(rect),
                            with: .color(isLit ? colorForLevel(values[col]) : dimColor)
                        )
                    }
                }
            }
            .frame(height: height)
            .clipped()
        }
    }

    private func colorForLevel(_ pct: Double) -> Color {
        if pct > 90 { return Color(hex: "FF6B6B").opacity(0.9) }
        if pct > 70 { return Color(hex: "FFD06B").opacity(0.8) }
        return Color(hex: "66CCFF").opacity(0.7)
    }
}

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

    private var timer: Timer?
    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
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
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isAvailable = false
                }
            }
        }
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

struct DockerStatsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dockerStats: DockerStatsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONTAINERS")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                if !dockerStats.containers.isEmpty {
                    Text("\(dockerStats.containers.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            if dockerStats.containers.isEmpty {
                Text("No containers running")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("NAME")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU")
                        .frame(width: 55, alignment: .trailing)
                    Text("MEM")
                        .frame(width: 80, alignment: .trailing)
                    Text("PIDs")
                        .frame(width: 35, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))

                ForEach(dockerStats.containers.sorted { parseCPUPercent($0.cpu) > parseCPUPercent($1.cpu) }) { container in
                    let cpuPct = parseCPUPercent(container.cpu)
                    let confidence = appState.activeHost.map {
                        NetworkTopologyStore.shared.containerConfidence(hostID: $0.id, containerName: container.name)
                    } ?? 0
                    HStack(spacing: 0) {
                        Circle()
                            .fill(confidenceColor(confidence))
                            .frame(width: 5, height: 5)
                            .padding(.trailing, 4)
                        Text(container.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(container.cpu)
                            .frame(width: 55, alignment: .trailing)
                        Text(shortMem(container.memUsage))
                            .frame(width: 80, alignment: .trailing)
                        Text(container.pids)
                            .frame(width: 35, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        GeometryReader { geo in
                            let maxPct = CGFloat(dockerStats.cpuCores) * 100.0
                            let fraction = min(cpuPct / maxPct, 1.0)
                            let barWidth = geo.size.width * fraction
                            Rectangle()
                                .fill(cpuBarColor(cpuPct, maxPct: maxPct).opacity(0.15))
                                .frame(width: barWidth)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    )
                    .cornerRadius(3)
                }
            }
        }
    }

    /// Parse "12.34%" → 12.34
    private func parseCPUPercent(_ s: String) -> CGFloat {
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        return CGFloat(Double(cleaned) ?? 0)
    }

    /// Color ramp for CPU bar: low=blue, mid=yellow, high=red (relative to max)
    private func cpuBarColor(_ pct: CGFloat, maxPct: CGFloat) -> Color {
        let fraction = pct / maxPct
        if fraction > 0.8 { return Color(hex: "FF6B6B") }
        if fraction > 0.4 { return Color(hex: "FFD06B") }
        return Color(hex: "66CCFF")
    }

    /// Confidence dot color: green >= 0.7, yellow >= 0.3, red < 0.3
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.7 { return Color(hex: "6BFF8E") }
        if confidence >= 0.3 { return Color(hex: "FFD06B") }
        return Color(hex: "FF6B6B")
    }

    /// Shorten "123.4MiB / 7.656GiB" → "123M / 7.7G"
    private func shortMem(_ s: String) -> String {
        let parts = s.components(separatedBy: " / ")
        return parts.map { part in
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("GiB") {
                if let v = Double(t.dropLast(3)) { return String(format: "%.1fG", v) }
            } else if t.hasSuffix("MiB") {
                if let v = Double(t.dropLast(3)) { return String(format: "%.0fM", v) }
            } else if t.hasSuffix("KiB") {
                if let v = Double(t.dropLast(3)) { return String(format: "%.0fK", v) }
            }
            return t
        }.joined(separator: "/")
    }
}

struct ConnectionPoolSection: View {
    @ObservedObject var appState: AppState
    @State private var muxStatus: [UUID: Bool] = [:]  // hostID -> mux alive

    /// Merge pool entries with pending entries, deduplicating by ID
    private var allConnections: [ConnectionInfo] {
        var seen = Set<String>()
        var result: [ConnectionInfo] = []
        // Pool entries first (they're authoritative)
        for conn in appState.connectionPool {
            seen.insert(conn.id)
            result.append(conn)
        }
        // Pending entries that aren't already in pool
        for conn in appState.pendingConnections where !seen.contains(conn.id) {
            seen.insert(conn.id)
            result.append(conn)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONNECTIONS")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(2)
                Spacer()
                let conns = allConnections
                let running = conns.filter { $0.isRunning || $0.connectionStatus.isTransient }.count
                let total = conns.count
                if total > 0 {
                    Text("\(running)/\(total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            let conns = allConnections
            if conns.isEmpty {
                Text("No connections")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("")
                        .frame(width: 8)
                    Text("SESSION")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("HOST")
                        .frame(width: 80, alignment: .trailing)
                    Text("STATUS")
                        .frame(width: 85, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))

                ForEach(conns) { conn in
                    HStack(spacing: 0) {
                        if conn.connectionStatus.isTransient {
                            // Pulsing dot for transient states
                            Circle()
                                .fill(Color(hex: conn.statusColor))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 3)
                                .opacity(0.6)
                                .modifier(PulseModifier())
                        } else {
                            Circle()
                                .fill(Color(hex: conn.statusColor))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 3)
                        }
                        Text(conn.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(conn.hostLabel)
                            .frame(width: 80, alignment: .trailing)
                            .lineLimit(1)
                        Text(conn.status)
                            .frame(width: 85, alignment: .trailing)
                            .foregroundColor(Color(hex: conn.statusColor).opacity(0.8))
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(conn.connectionStatus.isTransient ? 0.5 : 0.7))
                }

                // SSH mux status per remote host
                let remoteHosts = appState.hosts.filter { !$0.isLocal }
                if !remoteHosts.isEmpty {
                    Divider().background(Color.white.opacity(0.06)).padding(.vertical, 4)

                    HStack(spacing: 0) {
                        Text("")
                            .frame(width: 8)
                        Text("SSH MUX")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("STATUS")
                            .frame(width: 85, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))

                    ForEach(remoteHosts) { host in
                        let alive = muxStatus[host.id] ?? false
                        HStack(spacing: 0) {
                            Circle()
                                .fill(Color(hex: alive ? "6BFF8E" : "FF6B6B"))
                                .frame(width: 5, height: 5)
                                .padding(.trailing, 3)
                            Text(host.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(alive ? "multiplexed" : "no mux")
                                .frame(width: 85, alignment: .trailing)
                                .foregroundColor(Color(hex: alive ? "6BFF8E" : "FF6B6B").opacity(0.8))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
        .onAppear { refreshMuxStatus() }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            refreshMuxStatus()
        }
    }

    private func refreshMuxStatus() {
        let hosts = appState.hosts.filter { !$0.isLocal }
        DispatchQueue.global(qos: .utility).async {
            var status: [UUID: Bool] = [:]
            for host in hosts {
                status[host.id] = appState.sshMuxAlive(for: host)
            }
            DispatchQueue.main.async {
                muxStatus = status
            }
        }
    }
}

/// Simple pulse animation for transient connection states
private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1.0 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

struct RemindersSection: View {
    @ObservedObject var appState: AppState
    @StateObject private var reminders = RemindersManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(reminders.displayName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                let count = reminders.totalCount
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            if !reminders.accessGranted {
                Text("Reminders access not granted")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            } else if reminders.isMultiList {
                // Grouped display: each list shown with its own header
                if reminders.groupedReminders.isEmpty || reminders.groupedReminders.allSatisfy({ $0.reminders.isEmpty }) {
                    Text(reminders.emptyMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                } else {
                    ForEach(reminders.groupedReminders) { group in
                        if !group.reminders.isEmpty {
                            // List header
                            Text(group.name.uppercased())
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(appState.accentColor.opacity(0.6))
                                .tracking(1)
                                .padding(.top, group.id == reminders.groupedReminders.first?.id ? 0 : 4)

                            let visible = Array(group.reminders.prefix(5))
                            ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                                ReminderRow(reminder: reminder, appState: appState, manager: reminders)
                            }
                            if group.reminders.count > 5 {
                                Text("+\(group.reminders.count - 5) more")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.3))
                            }
                        }
                    }
                }
            } else if reminders.reminders.isEmpty {
                Text(reminders.emptyMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Single list or Today: flat display
                let visible = Array(reminders.reminders.prefix(7))
                ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                    ReminderRow(reminder: reminder, appState: appState, manager: reminders)
                }
                if reminders.reminders.count > 7 {
                    Text("+\(reminders.reminders.count - 7) more")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                }
            }
        }
        .onAppear {
            reminders.selectedLists = appState.appearance.remindersLists
            reminders.fetchReminders()
        }
        .onChange(of: appState.appearance.remindersLists) { _, newValue in
            reminders.selectedLists = newValue
            reminders.fetchReminders()
        }
    }
}

private struct ReminderRow: View {
    let reminder: EKReminder
    @ObservedObject var appState: AppState
    let manager: RemindersManager

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { manager.toggleComplete(reminder) }) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(reminder.isCompleted ? appState.accentColor : .gray.opacity(0.4))
            }
            .buttonStyle(.plain)

            Text(reminder.title ?? "Untitled")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(reminder.isCompleted ? .gray.opacity(0.3) : .white.opacity(0.8))
                .strikethrough(reminder.isCompleted)
                .lineLimit(1)

            Spacer()

            if let due = reminder.dueDateComponents, let hour = due.hour, let minute = due.minute {
                let isOverdue = isReminderOverdue(due)
                Text(String(format: "%d:%02d", hour, minute))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isOverdue && !reminder.isCompleted ? Color(hex: "FF6B6B") : .gray.opacity(0.4))
            }
        }
        .padding(.vertical, 2)
    }

    private func isReminderOverdue(_ components: DateComponents) -> Bool {
        guard let date = Calendar.current.date(from: components) else { return false }
        return date < Date()
    }
}
