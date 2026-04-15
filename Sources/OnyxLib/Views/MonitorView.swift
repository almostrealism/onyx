import SwiftUI
import EventKit

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
        reminder.isCompleted.toggle()
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

    private var monitor: MonitorManager { appState.monitor }
    private var dockerStats: DockerStatsManager { appState.dockerStats }

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                // Time + stats row: aux clocks left, main clock center, chips right
                ZStack {
                    // LEFT: Extra timezone clocks
                    if !appState.appearance.extraTimezones.isEmpty {
                        HStack(spacing: 20) {
                            ForEach(appState.appearance.extraTimezones.prefix(3), id: \.self) { tzId in
                                if let tz = TimeZone(identifier: tzId) {
                                    ExtraClockView(
                                        timeZone: tz,
                                        accentColor: appState.accentColor,
                                        use12Hour: appState.appearance.use12HourClock
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // CENTER: Main clock
                    TimeDisplay(accentColor: appState.accentColor, use12Hour: appState.appearance.use12HourClock)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // RIGHT: Stat chips
                    if let sample = monitor.latestSample {
                        HStack(spacing: 12) {
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
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 40)

                if let _ = monitor.latestSample {
                    // Interval label
                    HStack(spacing: 4) {
                        Text(monitor.useShortInterval ? "5s intervals" : "1m intervals")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                        Text("(T interval · M memory · C containers · P 12/24hr)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.25))
                    }

                    // Claude Code sessions banner (if any active) — stays
                    // full-width above the split.
                    if !appState.claudeSessions.activeSessions.isEmpty || !appState.claudeSessions.pendingPermissions.isEmpty {
                        ClaudeSessionsSection(appState: appState)
                            .padding(.horizontal, 40)
                    }

                    // Main region: vertical split. Left ~65% holds timing,
                    // CPU/MEM/GPU charts, then reminders directly underneath.
                    // Right ~35% holds containers then connections.
                    GeometryReader { geo in
                        let rightWidth = max(280, geo.size.width * 0.35)
                        HStack(alignment: .top, spacing: 0) {
                            VStack(alignment: .leading, spacing: 16) {
                                if appState.timing.isConfigured {
                                    TimingChartSection(timing: appState.timing, accentColor: appState.accentColor)
                                }
                                RemindersSection(appState: appState)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.trailing, 20)

                            Divider()
                                .background(Color.white.opacity(0.1))

                            VStack(alignment: .leading, spacing: 16) {
                                let cpuData = monitor.bucketedCPU()
                                if !cpuData.isEmpty {
                                    GridChart(
                                        title: "CPU",
                                        values: cpuData,
                                        accentColor: Color(hex: "66CCFF")
                                    )
                                }

                                let memData = monitor.showMemoryChart ? monitor.bucketedMemory() : []
                                let gpuData = monitor.bucketedGPU()
                                let hasMem = !memData.isEmpty && monitor.showMemoryChart
                                let hasGpu = !gpuData.isEmpty
                                let subChartHeight: CGFloat = 100

                                if hasMem && hasGpu {
                                    let halfHeight = (subChartHeight - 16) / 2
                                    GridChart(title: "MEMORY", values: memData,
                                              accentColor: Color(hex: "FFD06B"), height: halfHeight)
                                    GridChart(title: "GPU", values: gpuData,
                                              accentColor: Color(hex: "C06BFF"), height: halfHeight)
                                } else if hasMem {
                                    GridChart(title: "MEMORY", values: memData,
                                              accentColor: Color(hex: "FFD06B"), height: subChartHeight)
                                } else if hasGpu {
                                    GridChart(title: "GPU", values: gpuData,
                                              accentColor: Color(hex: "C06BFF"), height: subChartHeight)
                                }

                                if dockerStats.isAvailable {
                                    DockerStatsSection(appState: appState, dockerStats: dockerStats)
                                }
                                ConnectionPoolSection(appState: appState)
                            }
                            .frame(width: rightWidth, alignment: .topLeading)
                            .padding(.leading, 20)
                        }
                    }
                    .padding(.horizontal, 40)
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleAllContainers)) { _ in
            dockerStats.showAllContainers.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleClockFormat)) { _ in
            appState.appearance.use12HourClock.toggle()
            appState.saveAppearance()
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
    var use12Hour: Bool = false
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timeDigits)
                    .font(.system(size: 36, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))

                if use12Hour {
                    Text(ampmSuffix)
                        .font(.system(size: 14, weight: .light, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            HStack(spacing: 8) {
                Text(dateString)
                    .font(.system(size: 12, weight: .light, design: .monospaced))
                    .foregroundColor(accentColor.opacity(0.6))

                Text(utcString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var timeDigits: String {
        let f = DateFormatter()
        f.dateFormat = use12Hour ? "h:mm:ss" : "HH:mm:ss"
        return f.string(from: currentTime)
    }

    private var ampmSuffix: String {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f.string(from: currentTime)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: currentTime)
    }

    private var utcString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return "UTC " + f.string(from: currentTime)
    }
}

struct ExtraClockView: View {
    let timeZone: TimeZone
    let accentColor: Color
    var use12Hour: Bool = false
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(timeString)
                .font(.system(size: 16, weight: .ultraLight, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(accentColor.opacity(0.4))
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = use12Hour ? "h:mm a" : "HH:mm"
        f.timeZone = timeZone
        return f.string(from: currentTime)
    }

    private var label: String {
        // Use abbreviation if available, otherwise city name from identifier
        let abbrev = timeZone.abbreviation(for: currentTime) ?? ""
        let city = timeZone.identifier.split(separator: "/").last.map(String.init) ?? timeZone.identifier
        let displayCity = city.replacingOccurrences(of: "_", with: " ")
        return abbrev.isEmpty ? displayCity : "\(displayCity) \(abbrev)"
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

                let visCount = dockerStats.visibleContainers.count
                let totalCount = dockerStats.containers.count
                if totalCount > 0 {
                    Text(visCount == totalCount ? "\(totalCount)" : "\(visCount)/\(totalCount)")
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
                    Text("UP")
                        .frame(width: 38, alignment: .trailing)
                    Text("CPU")
                        .frame(width: 55, alignment: .trailing)
                    Text("MEM")
                        .frame(width: 80, alignment: .trailing)
                    Text("PIDs")
                        .frame(width: 35, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))

                ForEach(dockerStats.visibleContainers.sorted { parseCPUPercent($0.cpu) > parseCPUPercent($1.cpu) }) { container in
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
                        Text(container.uptime)
                            .frame(width: 38, alignment: .trailing)
                            .foregroundColor(.white.opacity(0.5))
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

                // Hidden idle containers indicator
                let hiddenCount = dockerStats.hiddenIdleCount
                if hiddenCount > 0 {
                    Text("\(hiddenCount) container\(hiddenCount == 1 ? "" : "s") with <1% CPU (C to show)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                        .padding(.top, 4)
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

// MARK: - Timing.app Chart

struct TimingChartSection: View {
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    private var avgPerDay: Double {
        let daysWithData = timing.dailyHours.filter { $0.hours > 0 }.count
        guard daysWithData > 0 else { return 0 }
        return timing.totalWeekHours / Double(daysWithData)
    }

    private var maxHours: Double {
        max(timing.dailyHours.map(\.hours).max() ?? 1, 1)
    }

    /// Consistent color palette for projects
    private static let projectColors = ["66CCFF", "6BFF8E", "FFD06B", "C06BFF", "FF6B6B", "FF6BCD", "6BFFD0"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TIME THIS WEEK")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)
                    .tracking(2)

                if !timing.filterProjectID.isEmpty {
                    Text(timing.filterProjectName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(accentColor.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accentColor.opacity(0.1))
                        .cornerRadius(3)
                }

                Spacer()

                if timing.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .colorScheme(.dark)
                }
            }

            // Top row: week bar chart (left) + 12-week heatmap (right)
            HStack(alignment: .top, spacing: 12) {
                // Stacked bar chart: one bar per day, segments per project
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(timing.dailyHours) { day in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if day.hours > 0 && day.projects.count > 1 {
                                    VStack(spacing: 0) {
                                        ForEach(day.projects) { slice in
                                            Rectangle()
                                                .fill(Color(hex: slice.color).opacity(0.75))
                                                .frame(height: max(1, CGFloat(slice.hours / maxHours) * 76))
                                        }
                                    }
                                    .cornerRadius(2)
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(day.hours > 0 ? Color(hex: day.projects.first?.color ?? "66CCFF").opacity(0.7) : Color.white.opacity(0.04))
                                        .frame(height: max(2, CGFloat(day.hours / maxHours) * 76))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 76)
                    HStack(spacing: 3) {
                        ForEach(timing.dailyHours) { day in
                            Text(day.dayLabel)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // 12-week heatmap, forced square cells
                if !timing.heatmap.isEmpty {
                    TimingHeatmapGrid(weeks: timing.heatmap)
                }
            }

            // Project totals legend
            if timing.projectTotals.count > 1 {
                HStack(spacing: 8) {
                    ForEach(timing.projectTotals.prefix(5)) { proj in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color(hex: proj.color))
                                .frame(width: 5, height: 5)
                            Text("\(proj.title)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                            Text(String(format: "%.0fh", proj.hours))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    Spacer()
                }
            }

            // Stats: two columns, big current number + small longer-range avg
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", timing.totalWeekHours))
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/wk", timing.avgHoursPerWeekLast4))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(4w avg)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", avgPerDay))
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs/day")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/day", timing.avgHoursPerDayLast30))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(30d avg)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                Spacer()
            }

            if let error = timing.lastError {
                Text(error)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "FF6B6B").opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

/// 12×7 grid showing daily hours over the last 12 weeks, colored against a
/// 40-hour-week target. Colors encode how close a single day is to the
/// one-seventh-of-40 = 5.71-hour ceiling: black = no data, blue = light,
/// green = healthy, red = over-target.
struct TimingHeatmapGrid: View {
    let weeks: [[Double]]  // [week][day] — week 0 oldest, day 0 Monday

    /// Reference hours for a "full" day under a 40-hour workweek.
    private static let dayReference: Double = 40.0 / 7.0

    /// Piecewise color ramp against the 40-hr-week target:
    ///   0%   → black
    ///   25%  → cold blue (low activity)
    ///   50%  → healthy green
    ///   75%  → red (at/over target)
    ///  100%+ → saturated red
    ///
    /// Between stops we interpolate linearly in RGB. 62.5% lands halfway
    /// between green (50%) and red (75%) — roughly half-green half-red.
    static func heatColor(hours: Double) -> Color {
        let t = min(max(hours / dayReference, 0), 1)
        // Stops: (threshold, r, g, b)
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.00, 0.00, 0.00),   // black
            (0.25, 0.15, 0.45, 0.95),   // cold blue
            (0.50, 0.20, 0.80, 0.40),   // healthy green
            (0.75, 1.00, 0.30, 0.20),   // red
            (1.00, 1.00, 0.20, 0.20)    // saturated red
        ]
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if t <= b.0 {
                let span = b.0 - a.0
                let frac = span > 0 ? (t - a.0) / span : 0
                return Color(
                    red: a.1 + (b.1 - a.1) * frac,
                    green: a.2 + (b.2 - a.2) * frac,
                    blue: a.3 + (b.3 - a.3) * frac
                )
            }
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
    }

    /// Fixed square cell size — guarantees the grid never stretches.
    private static let cellSize: CGFloat = 9
    private static let cellGap: CGFloat = 1

    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Sum of all 7 days for a given week column.
    private func weekTotal(_ week: Int) -> Double {
        weeks[week].reduce(0, +)
    }

    /// "Wed · 4.2 hrs · 28% of 15.0h week" — or just hours if the week was empty.
    private func tooltip(week: Int, day: Int) -> String {
        let hours = weeks[week][day]
        let total = weekTotal(week)
        let weeksAgo = (weeks.count - 1) - week
        let weekLabel: String = {
            if weeksAgo == 0 { return "this wk" }
            if weeksAgo == 1 { return "1 wk ago" }
            return "\(weeksAgo) wks ago"
        }()
        let dayName = Self.dayNames[day]
        if total <= 0 {
            return String(format: "%@ %@: %.1f hrs", dayName, weekLabel, hours)
        }
        let pct = hours / total * 100
        return String(format: "%@ %@: %.1f hrs · %.0f%% of %.1fh week",
                      dayName, weekLabel, hours, pct, total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(spacing: Self.cellGap) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: Self.cellGap) {
                        ForEach(0..<weeks.count, id: \.self) { week in
                            let hours = weeks[week][day]
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Self.heatColor(hours: hours))
                                .frame(width: Self.cellSize, height: Self.cellSize)
                                .help(tooltip(week: week, day: day))
                        }
                    }
                }
            }
            // Legend directly under the grid, same width
            HStack(spacing: 3) {
                Text("12W")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.35))
                HStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { i in
                        Rectangle()
                            .fill(Self.heatColor(hours: Double(i) / 24 * Self.dayReference))
                            .frame(width: 3, height: 3)
                    }
                }
                Text("40h")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
        .fixedSize()
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

// MARK: - Claude Code Sessions

struct ClaudeSessionsSection: View {
    @ObservedObject var appState: AppState

    private var manager: ClaudeSessionManager { appState.claudeSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "C06BFF"))
                Text("CLAUDE SESSIONS")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "C06BFF"))
                    .tracking(2)

                Spacer()

                Text("\(manager.activeSessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }

            // Permission requests (urgent, shown first)
            ForEach(manager.pendingPermissions) { request in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "FFD06B"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.toolName)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text(request.summary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { manager.approvePermission(request.id) }) {
                        Text("Allow")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "6BFF8E"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "6BFF8E").opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: { manager.denyPermission(request.id) }) {
                        Text("Deny")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(hex: "FF6B6B"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "FF6B6B").opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color(hex: "FFD06B").opacity(0.06))
                .cornerRadius(6)
            }

            // Active sessions
            ForEach(manager.activeSessions) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionStatusColor(session.status))
                        .frame(width: 6, height: 6)

                    Text(shortSessionId(session.id))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "C06BFF").opacity(0.7))
                        .frame(width: 50, alignment: .leading)

                    switch session.status {
                    case .running(let tool):
                        Text(tool)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                        if let input = session.toolInput, !input.isEmpty {
                            Text(input)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.5))
                                .lineLimit(1)
                        }
                    case .waitingPermission:
                        Text("waiting for permission")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "FFD06B"))
                            .modifier(PulseModifier())
                    case .idle:
                        Text("idle")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    case .stopped:
                        Text("stopped")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.3))
                    }

                    Spacer()

                    Text(relativeTime(session.lastSeen))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                }
            }
        }
    }

    private func sessionStatusColor(_ status: ClaudeActivity.ClaudeStatus) -> Color {
        switch status {
        case .running: return Color(hex: "6BFF8E")
        case .waitingPermission: return Color(hex: "FFD06B")
        case .idle: return Color(hex: "66CCFF").opacity(0.5)
        case .stopped: return .gray.opacity(0.3)
        }
    }

    private func shortSessionId(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 5 { return "now" }
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
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

                let total = reminders.totalCount
                if total > 0 {
                    Text("\(total)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            if !reminders.accessGranted {
                Text("Reminders access not granted")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            } else if reminders.isMultiList {
                // Grouped display: 2-column grid layout
                let nonEmpty = reminders.groupedReminders.filter { !$0.reminders.isEmpty }
                if nonEmpty.isEmpty {
                    Text(reminders.emptyMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        // Column 1: odd-indexed groups (0, 2, 4, ...)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(nonEmpty.enumerated()).filter { $0.offset % 2 == 0 }, id: \.element.id) { _, group in
                                ReminderListColumn(group: group, appState: appState, reminders: reminders)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Column 2: even-indexed groups (1, 3, 5, ...)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(nonEmpty.enumerated()).filter { $0.offset % 2 == 1 }, id: \.element.id) { _, group in
                                ReminderListColumn(group: group, appState: appState, reminders: reminders)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if reminders.reminders.isEmpty {
                Text(reminders.emptyMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Single list or Today: flat display
                let visible = Array(reminders.reminders.prefix(14))
                ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                    ReminderRow(reminder: reminder, appState: appState, manager: reminders)
                }
                if reminders.reminders.count > 14 {
                    Text("+\(reminders.reminders.count - 14) more")
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

private struct ReminderListColumn: View {
    let group: ReminderListGroup
    @ObservedObject var appState: AppState
    let reminders: RemindersManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(appState.accentColor.opacity(0.6))
                .tracking(1)

            let visible = Array(group.reminders.prefix(14))
            ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                ReminderRow(reminder: reminder, appState: appState, manager: reminders)
            }
            if group.reminders.count > 14 {
                Text("+\(group.reminders.count - 14) more")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }
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
