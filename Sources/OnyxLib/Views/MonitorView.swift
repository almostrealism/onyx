import SwiftUI
import EventKit

// MARK: - Monitor font scaling
//
// All text in MonitorView and its descendants scales with the user's
// UI font size preference (Settings → UI font size). The "design"
// sizes used at each call site are the values that look right at the
// default scale of 1.0 (when uiFontSize = 12). At other sizes they
// scale proportionally so the visual hierarchy stays intact.

private struct MonitorFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Scale factor applied to all `.monitorFont(...)` calls inside
    /// MonitorView. Injected at the MonitorView root from
    /// `appearance.uiFontSize / 12`.
    var monitorFontScale: CGFloat {
        get { self[MonitorFontScaleKey.self] }
        set { self[MonitorFontScaleKey.self] = newValue }
    }
}

extension View {
    /// Use this instead of `.font(.system(size:weight:design:))` for
    /// any text or icon inside MonitorView. The `size` argument is the
    /// design intent at the default UI scale; the ambient
    /// `monitorFontScale` multiplies it. Default design is
    /// `.monospaced` since that's what 95% of MonitorView uses; pass
    /// `.default` explicitly for icons.
    func monitorFont(size: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design = .monospaced) -> some View {
        modifier(MonitorFontModifier(baseSize: size, weight: weight, design: design))
    }
}

private struct MonitorFontModifier: ViewModifier {
    @Environment(\.monitorFontScale) private var scale
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight, design: design))
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
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                        Text("(T interval · M memory · C containers · P 12/24hr · S simple)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.25))
                    }

                    // Claude Code sessions banner (if any active) — stays
                    // full-width above the split.
                    if !appState.claudeSessions.activeSessions.isEmpty || !appState.claudeSessions.pendingPermissions.isEmpty {
                        ClaudeSessionsSection(appState: appState)
                            .padding(.horizontal, 40)
                    }

                    if appState.showSimpleMonitor {
                        SimpleMonitorBody(
                            monitor: monitor,
                            dockerStats: dockerStats,
                            timing: appState.timing,
                            accentColor: appState.accentColor
                        )
                        .padding(.horizontal, 40)
                    } else {
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
                                // Two-column layout below the timing chart:
                                // - Left:  session notes → reminders
                                // - Right: open PRs → pipelines
                                // Either column can be sparse without
                                // crowding the other; the columns just
                                // collapse vertically.
                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 16) {
                                        SessionNotesSection(appState: appState)
                                        RemindersSection(appState: appState)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    VStack(alignment: .leading, spacing: 16) {
                                        PullRequestsSection(appState: appState)
                                        PipelinesSection(appState: appState)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
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
                                } else {
                                    CPUUnavailableCard(
                                        message: monitor.cpuDiagnostic
                                            ?? "CPU usage unavailable on this host."
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
                    } // end else (detailed view)
                } else if let error = monitor.lastError {
                    // Even when stats failed, surface the connection pool
                    // so the user can diagnose any host's mux state — that
                    // diagnostic panel is exactly what's needed to figure
                    // out *why* the stats aren't coming in.
                    VStack(spacing: 16) {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .monitorFont(size: 20, design: .default)
                                .foregroundColor(Color(hex: "FF6B6B"))
                            Text(error)
                                .monitorFont(size: 12)
                                .foregroundColor(Color(hex: "FF6B6B").opacity(0.8))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                            Text("Retrying every 5s... (attempt \(monitor.pollCount))")
                                .monitorFont(size: 10)
                                .foregroundColor(.gray.opacity(0.4))
                        }
                        ConnectionPoolSection(appState: appState)
                            .frame(maxWidth: 480)
                    }
                    .padding(.horizontal, 40)
                } else {
                    VStack(spacing: 16) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .colorScheme(.dark)
                            Text("Fetching stats from \(appState.activeHost?.label ?? "host")...")
                                .monitorFont(size: 12)
                                .foregroundColor(.gray.opacity(0.5))
                        }
                        // Connection pool is always useful — especially
                        // while we're stuck waiting for the active host's
                        // first sample.
                        ConnectionPoolSection(appState: appState)
                            .frame(maxWidth: 480)
                    }
                    .padding(.horizontal, 40)
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
        // Scale every `.monitorFont(...)` in this view tree by the user's
        // UI font size preference. Default (uiFontSize == 12) → 1.0.
        .environment(\.monitorFontScale, appState.appearance.uiFontSize / 12.0)
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
                    .monitorFont(size: 36, weight: .ultraLight)
                    .foregroundColor(.white.opacity(0.9))

                if use12Hour {
                    Text(ampmSuffix)
                        .monitorFont(size: 14, weight: .light)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            HStack(spacing: 8) {
                Text(dateString)
                    .monitorFont(size: 12, weight: .light)
                    .foregroundColor(accentColor.opacity(0.6))

                Text(utcString)
                    .monitorFont(size: 10)
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
                .monitorFont(size: 16, weight: .ultraLight)
                .foregroundColor(.white.opacity(0.7))

            Text(label)
                .monitorFont(size: 9)
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
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)
            Text(value)
                .monitorFont(size: 13, weight: .medium)
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
                .monitorFont(size: 10, weight: .medium)
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

struct CPUUnavailableCard: View {
    let message: String
    var height: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(Color(hex: "66CCFF"))
                .tracking(2)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .monitorFont(size: 11, design: .default)
                    .foregroundColor(Color(hex: "FFD06B").opacity(0.8))
                Text(message)
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.7))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(Color.white.opacity(0.03))
        }
    }
}

// MARK: - Simple Monitor view
//
// "S" toggles a stripped-down layout: same headline at top, then giant
// CPU + MEM + GPU charts, a compact strip of the top-CPU containers,
// and a small weekly Timing tile in the bottom-right. Designed for
// at-a-glance ambient monitoring rather than the full diagnostic
// dashboard.

struct SimpleMonitorBody: View {
    @ObservedObject var monitor: MonitorManager
    @ObservedObject var dockerStats: DockerStatsManager
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    var body: some View {
        GeometryReader { geo in
            // Reserve a fixed strip for containers + timing tile, give
            // the rest to the charts. CPU gets the lion's share; MEM
            // and GPU split the bottom portion of the chart area.
            let bottomStripHeight: CGFloat = 56
            let chartArea = max(0, geo.size.height - bottomStripHeight - 16)
            let cpuHeight = chartArea * 0.55
            let subHeight = max(40, chartArea * 0.42)

            VStack(alignment: .leading, spacing: 8) {
                // CPU chart — giant.
                let cpuData = monitor.bucketedCPU()
                if !cpuData.isEmpty {
                    GridChart(title: "CPU", values: cpuData,
                              accentColor: Color(hex: "66CCFF"),
                              height: cpuHeight)
                } else {
                    CPUUnavailableCard(
                        message: monitor.cpuDiagnostic
                            ?? "CPU usage unavailable on this host.",
                        height: cpuHeight
                    )
                }

                // MEM and GPU side by side. Render whichever are
                // available; if neither, the row is just empty space.
                let memData = monitor.showMemoryChart ? monitor.bucketedMemory() : []
                let gpuData = monitor.bucketedGPU()
                let hasMem = !memData.isEmpty && monitor.showMemoryChart
                let hasGpu = !gpuData.isEmpty
                if hasMem || hasGpu {
                    HStack(spacing: 12) {
                        if hasMem {
                            GridChart(title: "MEMORY", values: memData,
                                      accentColor: Color(hex: "FFD06B"),
                                      height: subHeight)
                                .frame(maxWidth: .infinity)
                        }
                        if hasGpu {
                            GridChart(title: "GPU", values: gpuData,
                                      accentColor: Color(hex: "C06BFF"),
                                      height: subHeight)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Bottom strip: top-CPU containers on the left,
                // weekly Timing tile on the right.
                HStack(alignment: .center, spacing: 12) {
                    SimpleContainersStrip(dockerStats: dockerStats)
                    Spacer(minLength: 12)
                    if timing.isConfigured {
                        WeeklyTimingTile(timing: timing, accentColor: accentColor)
                    }
                }
                .frame(height: bottomStripHeight)
            }
        }
    }
}

/// Up to 3 containers with the highest current CPU%, rendered as a
/// compact horizontal strip. Empty (zero-height) when docker isn't
/// available so the timing tile sits flush against the leading edge.
struct SimpleContainersStrip: View {
    @ObservedObject var dockerStats: DockerStatsManager

    var body: some View {
        if dockerStats.isAvailable {
            let top = dockerStats.visibleContainers
                .sorted { DockerStatsManager.parseCPUPct($0.cpu) > DockerStatsManager.parseCPUPct($1.cpu) }
                .prefix(3)
            // Match the full list: bar saturates at total-cores × 100% so
            // a single hot container on a many-core box is correctly dim.
            let maxPct = CGFloat(max(1, dockerStats.cpuCores)) * 100.0
            HStack(spacing: 10) {
                ForEach(Array(top), id: \.id) { c in
                    SimpleContainerPill(
                        name: c.name,
                        cpuText: c.cpu,
                        cpuPct: CGFloat(DockerStatsManager.parseCPUPct(c.cpu)),
                        maxPct: maxPct
                    )
                }
            }
        } else {
            EmptyView()
        }
    }
}

/// One pill in the simple-mode containers strip. Renders the same
/// proportional CPU bar + color ramp as the full DockerStatsSection row,
/// just compacted into a chip-sized container.
private struct SimpleContainerPill: View {
    let name: String
    let cpuText: String
    let cpuPct: CGFloat
    let maxPct: CGFloat

    var body: some View {
        let color = monitorCPUBarColor(cpuPct, maxPct: maxPct)
        HStack(spacing: 6) {
            Text(name)
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(monitorCompactCPU(cpuText))
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.04)
                    let fraction = min(cpuPct / maxPct, 1.0)
                    Rectangle()
                        .fill(color.opacity(0.22))
                        .frame(width: geo.size.width * fraction)
                }
            }
        )
        .cornerRadius(4)
    }
}

/// Color ramp for container CPU bars, shared between DockerStatsSection
/// (the full list) and SimpleContainersStrip (the simple-mode strip) so
/// both views use the same visual language: blue at low CPU, yellow in
/// the middle, red when a container is dominating the box. Thresholds
/// are fractions of `maxPct` (total cores × 100%), matching how the
/// full list interprets saturation.
fileprivate func monitorCPUBarColor(_ pct: CGFloat, maxPct: CGFloat) -> Color {
    let fraction = pct / max(1, maxPct)
    if fraction > 0.8 { return Color(hex: "FF6B6B") }
    if fraction > 0.4 { return Color(hex: "FFD06B") }
    return Color(hex: "66CCFF")
}

/// Weekly hours + per-day average for the currently-filtered Timing
/// project. Renders only when timing is configured AND the current
/// week has any data.
struct WeeklyTimingTile: View {
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    var body: some View {
        let total = timing.totalWeekHours
        let daysWithData = timing.dailyHours.filter { $0.hours > 0 }.count
        let perDay = daysWithData > 0 ? total / Double(daysWithData) : 0

        if total > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatHours(total))
                    .monitorFont(size: 18, weight: .light)
                    .foregroundColor(accentColor)
                HStack(spacing: 4) {
                    Text(formatHours(perDay))
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.7))
                    Text("/day")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
            .cornerRadius(4)
        }
    }

    private func formatHours(_ h: Double) -> String {
        // 8.0 → "8h"; 8.5 → "8.5h"; 0.25 → "15m"
        if h < 1 {
            let mins = Int(round(h * 60))
            return "\(mins)m"
        }
        // Drop trailing .0
        let rounded = (h * 10).rounded() / 10
        if rounded == rounded.rounded(.down) {
            return "\(Int(rounded))h"
        }
        return String(format: "%.1fh", rounded)
    }
}

struct DockerStatsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dockerStats: DockerStatsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONTAINERS")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                let visCount = dockerStats.visibleContainers.count
                let totalCount = dockerStats.containers.count
                if totalCount > 0 {
                    Text(visCount == totalCount ? "\(totalCount)" : "\(visCount)/\(totalCount)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            if dockerStats.containers.isEmpty {
                Text("No containers running")
                    .monitorFont(size: 11)
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
                .monitorFont(size: 9, weight: .medium)
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.75)
                        Text(monitorCompactCPU(container.cpu))
                            .frame(width: 55, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.7)
                        Text(shortMem(container.memUsage))
                            .frame(width: 80, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.7)
                        Text(container.pids)
                            .frame(width: 35, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.75)
                    }
                    .monitorFont(size: 11)
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
                        .monitorFont(size: 9)
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

    /// Color ramp for CPU bar: forwards to the file-level helper so the
    /// simple-mode strip and the full list stay in lockstep.
    private func cpuBarColor(_ pct: CGFloat, maxPct: CGFloat) -> Color {
        monitorCPUBarColor(pct, maxPct: maxPct)
    }

    /// Confidence dot color: green >= 0.7, yellow >= 0.3, red < 0.3
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.7 { return Color(hex: "6BFF8E") }
        if confidence >= 0.3 { return Color(hex: "FFD06B") }
        return Color(hex: "FF6B6B")
    }

    /// Shorten "12.34MiB / 7.656GiB" → "12M/7.7G".
    /// Forwards to the file-level `monitorShortMem` so the simple-mode
    /// strip and full list share one set of formatting rules.
    private func shortMem(_ s: String) -> String { monitorShortMem(s) }
}

/// Adaptive CPU formatting — fewer decimal places as the magnitude grows,
/// so we use the column width sensibly instead of burning four chars on
/// trailing zeros at high CPU. `7.66%` over `123.45%` is the same number
/// of characters; the eye-readable digits are what matters.
func monitorCompactCPU(_ s: String) -> String {
    let cleaned = s.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "%", with: "")
    guard let v = Double(cleaned) else { return s }
    if v >= 1000 { return String(format: "%.0f%%", v) }   // e.g. "1024%"
    if v >= 100  { return String(format: "%.0f%%", v) }   // e.g. "150%"
    if v >= 10   { return String(format: "%.1f%%", v) }   // e.g. "12.3%"
    return String(format: "%.2f%%", v)                    // e.g. "0.05%"
}

/// Adaptive memory formatting. Goal: every result is ≤ 4 chars + unit
/// letter, so a worst-case "9999M/9999G" fits the 80px column without
/// wrap or truncation. Bigger numbers drop more decimals.
func monitorShortMem(_ s: String) -> String {
    let parts = s.components(separatedBy: " / ")
    return parts.map(monitorCompactSize).joined(separator: "/")
}

func monitorCompactSize(_ part: String) -> String {
    let t = part.trimmingCharacters(in: .whitespaces)
    let suffixes: [(String, String)] = [
        ("GiB", "G"), ("MiB", "M"), ("KiB", "K"),
        ("GB",  "G"), ("MB",  "M"), ("KB",  "K"),
        ("B",   "B"),
    ]
    for (input, unit) in suffixes where t.hasSuffix(input) {
        let numStr = t.dropLast(input.count).trimmingCharacters(in: .whitespaces)
        guard let v = Double(numStr) else { return t }
        if v >= 1000 { return String(format: "%.0f%@", v / 1024, "T") }
        if v >= 100  { return String(format: "%.0f%@", v, unit) }    // "888G"
        if v >= 10   { return String(format: "%.1f%@", v, unit) }    // "12.3G"
        if v >= 1    { return String(format: "%.1f%@", v, unit) }    // "1.2G"
        return String(format: "%.2f%@", v, unit)                     // "0.12G"
    }
    return t
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
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(accentColor)
                    .tracking(2)

                if !timing.filterProjectID.isEmpty {
                    Text(timing.filterProjectName)
                        .monitorFont(size: 9, weight: .medium)
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

            // Top row: week bar chart (left) + 26-week heatmap (right)
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
                                .monitorFont(size: 8)
                                .foregroundColor(.gray.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // 26-week heatmap, forced square cells
                if !timing.heatmap.isEmpty {
                    TimingHeatmapGrid(weeks: timing.heatmap, anchorMonday: timing.heatmapAnchorMonday)
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
                                .monitorFont(size: 9)
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                            Text(String(format: "%.0fh", proj.hours))
                                .monitorFont(size: 9, weight: .medium)
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
                            .monitorFont(size: 18, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/wk", timing.avgHoursPerWeekLast4))
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(4w avg)")
                            .monitorFont(size: 8)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", avgPerDay))
                            .monitorFont(size: 18, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs/day")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/day", timing.avgHoursPerDayLast30))
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(30d avg)")
                            .monitorFont(size: 8)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                Spacer()
            }

            if let error = timing.lastError {
                Text(error)
                    .monitorFont(size: 9)
                    .foregroundColor(Color(hex: "FF6B6B").opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

/// 26×7 grid showing daily hours over the last 26 weeks (half a year), colored against a
/// 40-hour-week target. Colors encode how close a single day is to the
/// one-seventh-of-40 = 5.71-hour ceiling: black = no data, blue = light,
/// green = healthy, red = over-target.
struct TimingHeatmapGrid: View {
    let weeks: [[Double]]  // [week][day] — week 0 oldest, day 0 Monday
    let anchorMonday: Date  // Monday of the rightmost (current) week

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

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Compute the actual date for a cell.
    private func cellDate(week: Int, day: Int) -> Date {
        let weeksBack = (weeks.count - 1) - week
        let daysBack = weeksBack * 7 - day
        return Calendar.current.date(byAdding: .day, value: -daysBack, to: anchorMonday)!
    }

    /// "Wed Apr 2: 4.2 hrs · 28% of 15.0h week"
    private func tooltip(week: Int, day: Int) -> String {
        let hours = weeks[week][day]
        let total = weekTotal(week)
        let date = cellDate(week: week, day: day)
        let dayName = Self.dayNames[day]
        let dateStr = Self.tooltipDateFormatter.string(from: date)
        if total <= 0 {
            return String(format: "%@ %@: %.1f hrs", dayName, dateStr, hours)
        }
        let pct = hours / total * 100
        return String(format: "%@ %@: %.1f hrs · %.0f%% of %.1fh week",
                      dayName, dateStr, hours, pct, total)
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
                Text("26W")
                    .monitorFont(size: 7)
                    .foregroundColor(.gray.opacity(0.35))
                HStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { i in
                        Rectangle()
                            .fill(Self.heatColor(hours: Double(i) / 24 * Self.dayReference))
                            .frame(width: 3, height: 3)
                    }
                }
                Text("40h")
                    .monitorFont(size: 7)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
        .fixedSize()
    }
}

struct ConnectionPoolSection: View {
    @ObservedObject var appState: AppState
    /// Observe the keeper directly — `stateGeneration` bumps on every
    /// per-host slot mutation. SwiftUI re-renders this whole view tree
    /// (column + expanded panel) in the same pass, so they CAN'T get
    /// out of sync the way they did under the old cached-dict + 10s
    /// timer approach (where the column showed "no mux" but the
    /// expanded panel showed "alive" because they sampled the state
    /// at different times).
    @ObservedObject private var keeper = SSHKeeper.shared
    /// Which hostID currently has its diagnostic panel expanded inline.
    @State private var expandedDiagHost: UUID?
    /// Cached diagnostics indexed by hostID. Re-fetched when the row is
    /// expanded; cleared when collapsed.
    @State private var muxDiagnostics: [UUID: SSHMuxDiagnostic] = [:]
    @State private var connectTests: [UUID: SSHConnectTest] = [:]
    @State private var connectInFlight: Set<UUID> = []

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
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)
                Spacer()
                let conns = allConnections
                let running = conns.filter { $0.isRunning || $0.connectionStatus.isTransient }.count
                let total = conns.count
                if total > 0 {
                    Text("\(running)/\(total)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            let conns = allConnections
            if conns.isEmpty {
                Text("No connections")
                    .monitorFont(size: 11)
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
                .monitorFont(size: 9, weight: .medium)
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
                    .monitorFont(size: 11)
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
                    .monitorFont(size: 9, weight: .medium)
                    .foregroundColor(.gray.opacity(0.4))

                    ForEach(remoteHosts) { host in
                        // Read directly from the keeper. Both this and
                        // the expanded panel below source from the same
                        // call, in the same SwiftUI pass — divergence is
                        // structurally impossible. SwiftUI re-renders
                        // on any keeper.stateGeneration bump because
                        // we @ObservedObject the keeper above.
                        let alive = SSHKeeper.shared.isMuxAlive(for: host)
                        let expanded = expandedDiagHost == host.id
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: { toggleDiagnostic(for: host) }) {
                                HStack(spacing: 0) {
                                    Circle()
                                        .fill(Color(hex: alive ? "6BFF8E" : "FF6B6B"))
                                        .frame(width: 5, height: 5)
                                        .padding(.trailing, 3)
                                    Text(host.label)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                    Image(systemName: expanded
                                          ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundColor(.gray.opacity(0.4))
                                        .padding(.trailing, 6)
                                    Text(alive ? "multiplexed" : "no mux")
                                        .frame(width: 85, alignment: .trailing)
                                        .foregroundColor(Color(hex: alive ? "6BFF8E" : "FF6B6B").opacity(0.8))
                                }
                                .monitorFont(size: 11)
                                .foregroundColor(.white.opacity(0.7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded {
                                SSHDiagnosticPanel(
                                    host: host,
                                    diagnostic: muxDiagnostics[host.id],
                                    connectTest: connectTests[host.id],
                                    isTesting: connectInFlight.contains(host.id),
                                    onReset: { resetMux(for: host) },
                                    onTestConnect: { runConnectTest(for: host) }
                                )
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
        }
        // No timer-based refresh needed — keeper.stateGeneration
        // bumps push updates to this view automatically. Dead /
        // failover / re-establish events surface within one render
        // cycle of when the keeper observed them.
    }

    // refreshMuxStatus / muxStatus have been removed — the keeper's
    // ObservableObject + stateGeneration is now the single source the
    // view binds to. Per-row alive flags are read directly from
    // SSHKeeper.shared.isMuxAlive at render time.

    private func toggleDiagnostic(for host: HostConfig) {
        if expandedDiagHost == host.id {
            expandedDiagHost = nil
            return
        }
        expandedDiagHost = host.id
        // Fetch fresh diagnostic in the background — the `ssh -O check`
        // is bounded by its 3s kill timer, so this can never block the UI
        // for long.
        DispatchQueue.global(qos: .userInitiated).async {
            let diag = appState.diagnoseSSHMux(for: host)
            DispatchQueue.main.async {
                muxDiagnostics[host.id] = diag
            }
        }
    }

    private func resetMux(for host: HostConfig) {
        appState.resetSSHMux(for: host)
        // Re-run the diagnostic immediately so the user sees the new
        // (empty) state right away. The status column updates via the
        // keeper's @Published stateGeneration; no manual sync needed.
        DispatchQueue.global(qos: .userInitiated).async {
            let diag = appState.diagnoseSSHMux(for: host)
            DispatchQueue.main.async {
                muxDiagnostics[host.id] = diag
            }
        }
    }

    private func runConnectTest(for host: HostConfig) {
        connectInFlight.insert(host.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = appState.testSSHConnection(for: host)
            DispatchQueue.main.async {
                connectTests[host.id] = result
                connectInFlight.remove(host.id)
            }
        }
    }
}

/// Inline diagnostic panel for a single host. Shown under the SSH MUX row
/// when the user expands it. Renders the captured ssh command + output +
/// socket state, with actions to reset the mux or run a fresh
/// connection test.
private struct SSHDiagnosticPanel: View {
    let host: HostConfig
    let diagnostic: SSHMuxDiagnostic?
    let connectTest: SSHConnectTest?
    let isTesting: Bool
    let onReset: () -> Void
    let onTestConnect: () -> Void
    @State private var lastReapResult: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Supervisor (SSHKeeper) state. Goes first because this is
            // what the user actually wants to know — "is the supervisor
            // keeping things alive for me?" The legacy point-in-time
            // diagnostic still appears below.
            if let keeper = SSHKeeper.shared.state(for: host) {
                row("ACTIVE",
                    slotSummary(keeper.primary,
                                label: keeper.primarySlot == 0 ? "A" : "B"),
                    color: keeper.primary.alive ? "6BFF8E" : "FF6B6B")
                row("SPARE",
                    slotSummary(keeper.spare,
                                label: keeper.primarySlot == 0 ? "B" : "A"),
                    color: keeper.spare.alive ? "6BFF8E"
                          : (keeper.spare.establishing ? "FFD06B" : "FF6B6B"))
                if let rot = keeper.lastRotationAt {
                    row("ROTATE",
                        "last \(formatAge(Date().timeIntervalSince(rot))) ago · "
                          + "next in \(formatAge(max(0, SSHKeeper.rotationInterval - Date().timeIntervalSince(rot))))",
                        color: nil)
                }
            } else {
                row("KEEPER", "not yet observed", color: nil)
            }
            Divider().background(Color.white.opacity(0.06)).padding(.vertical, 2)
            if let d = diagnostic {
                row("STATUS", d.summary, color: d.muxAlive ? "6BFF8E" : "FF6B6B")
                row("SOCKET",
                    d.socketExists
                        ? "\(d.controlPath) — \(formatAge(d.socketAgeSeconds))"
                        : "(missing)",
                    color: nil)
                row("EXIT", d.checkExitCode.map(String.init) ?? "(no exit)",
                    color: nil)
                if !d.checkOutput.isEmpty {
                    Text("SSH OUTPUT")
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(.gray.opacity(0.5))
                        .tracking(1)
                        .padding(.top, 2)
                    ScrollView {
                        Text(d.checkOutput)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 80)
                }
                Text(d.checkCommand)
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.5))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text("Loading diagnostic…")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.4))
            }

            if let t = connectTest {
                Divider().background(Color.white.opacity(0.06))
                Text(t.success ? "CONNECT OK" : "CONNECT FAILED (exit \(t.exitCode.map(String.init) ?? "?"))")
                    .monitorFont(size: 9, weight: .medium)
                    .foregroundColor(Color(hex: t.success ? "6BFF8E" : "FF6B6B"))
                    .tracking(1)
                if !t.output.isEmpty {
                    ScrollView {
                        Text(t.output)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.7))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack(spacing: 8) {
                Button(action: onReset) {
                    Text("Reset mux")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                Button(action: onTestConnect) {
                    Text(isTesting ? "Testing…" : "Test connection")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(isTesting)
                Spacer()
                // Kill switch — disables the entire supervisor when the
                // user suspects it's misbehaving. Stops all new SSH
                // calls, freezes existing slot state for the UI.
                Button(action: {
                    SSHKeeper.shared.setEnabled(!SSHKeeper.shared.enabled)
                }) {
                    Text(SSHKeeper.shared.enabled ? "Disable keeper" : "Enable keeper")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SSHKeeper.shared.enabled
                                    ? Color(hex: "FF6B6B").opacity(0.2)
                                    : Color(hex: "6BFF8E").opacity(0.2))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.top, 4)

            // Global, host-independent: reap every ssh process the
            // keeper has spawned (or that anyone has spawned with a
            // ControlPath in our mux dir). Equivalent to running the
            // ssh-leak-cleanup.sh script. Use when accumulated orphans
            // have started tripping the remote sshd MaxStartups.
            HStack(spacing: 8) {
                Button(action: {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = SSHKeeper.shared.reapAll()
                        DispatchQueue.main.async {
                            lastReapResult = "Killed \(result.killed), refused \(result.refused)"
                        }
                    }
                }) {
                    Text("Reap all SSH (nuclear)")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "FF6B6B").opacity(0.25))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                Button(action: {
                    let dump = SSHKeeper.shared.inventoryDump()
                    // Drop on the pasteboard so the user can share it.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dump, forType: .string)
                    lastReapResult = "Inventory copied to clipboard"
                }) {
                    Text("Copy inventory")
                        .monitorFont(size: 10)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                if let summary = lastReapResult {
                    Text(summary)
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.6))
                }
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .cornerRadius(4)
        .padding(.leading, 14)
    }

    private func row(_ label: String, _ value: String, color: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .monitorFont(size: 10)
                .foregroundColor(color.map { Color(hex: $0) } ?? .white.opacity(0.7))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatAge(_ seconds: TimeInterval?) -> String {
        guard let s = seconds else { return "?" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }

    /// Compact one-line summary of a slot for the keeper rows. Shows
    /// liveness, smoke-test status, and age since establish.
    private func slotSummary(_ slot: SSHKeeper.SlotState, label: String) -> String {
        let aliveTag: String
        if slot.alive {
            aliveTag = slot.lastSmokeTestFailed ? "alive (smoke fail)" : "alive"
        } else if slot.establishing {
            aliveTag = "establishing…"
        } else {
            aliveTag = "DEAD"
        }
        var parts = ["slot \(label)", aliveTag]
        if let est = slot.establishedAt, slot.alive {
            parts.append("age \(formatAge(Date().timeIntervalSince(est)))")
        }
        return parts.joined(separator: " · ")
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
                    .monitorFont(size: 10, design: .default)
                    .foregroundColor(Color(hex: "C06BFF"))
                Text("CLAUDE SESSIONS")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(Color(hex: "C06BFF"))
                    .tracking(2)

                Spacer()

                Text("\(manager.activeSessions.count)")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.4))
            }

            // Permission requests (urgent, shown first)
            ForEach(manager.pendingPermissions) { request in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield")
                        .monitorFont(size: 12, design: .default)
                        .foregroundColor(Color(hex: "FFD06B"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.toolName)")
                            .monitorFont(size: 11, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text(request.summary)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { manager.approvePermission(request.id) }) {
                        Text("Allow")
                            .monitorFont(size: 10, weight: .medium)
                            .foregroundColor(Color(hex: "6BFF8E"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "6BFF8E").opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: { manager.denyPermission(request.id) }) {
                        Text("Deny")
                            .monitorFont(size: 10, weight: .medium)
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
                        .monitorFont(size: 10)
                        .foregroundColor(Color(hex: "C06BFF").opacity(0.7))
                        .frame(width: 50, alignment: .leading)

                    switch session.status {
                    case .running(let tool):
                        Text(tool)
                            .monitorFont(size: 11, weight: .medium)
                            .foregroundColor(.white.opacity(0.8))
                        if let input = session.toolInput, !input.isEmpty {
                            Text(input)
                                .monitorFont(size: 10)
                                .foregroundColor(.gray.opacity(0.5))
                                .lineLimit(1)
                        }
                    case .waitingPermission:
                        Text("waiting for permission")
                            .monitorFont(size: 11)
                            .foregroundColor(Color(hex: "FFD06B"))
                            .modifier(PulseModifier())
                    case .idle:
                        Text("idle")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.4))
                    case .stopped:
                        Text("stopped")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.3))
                    }

                    Spacer()

                    Text(relativeTime(session.lastSeen))
                        .monitorFont(size: 9)
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

/// Lists the user-supplied status notes attached to currently-existing
/// sessions, sorted by recency. Hides itself entirely when there are
/// no notes so the monitor doesn't carry a dead heading.
struct SessionNotesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SessionNotesStore.shared

    var body: some View {
        let entries = store.activeNotes(in: appState.allSessions)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SESSION NOTES")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    Text("⌘; to add")
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                }
                ForEach(entries, id: \.session.id) { entry in
                    SessionNoteRow(
                        session: entry.session,
                        note: entry.note,
                        isActive: appState.activeSession?.id == entry.session.id,
                        accentColor: appState.accentColor,
                        onTap: { appState.activeSession = entry.session }
                    )
                }
            }
        }
    }
}

private struct SessionNoteRow: View {
    let session: TmuxSession
    let note: SessionNote
    let isActive: Bool
    let accentColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(isActive ? accentColor : Color.gray.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.text)
                        .monitorFont(size: 12)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(session.displayLabel)
                            .monitorFont(size: 10)
                            .foregroundColor(accentColor.opacity(0.7))
                        Text(note.updated, style: .relative)
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.white.opacity(0.04) : Color.clear)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

/// Side-by-side companion to SessionNotesSection in the monitor overlay.
/// Reads from `PullRequestManager.shared` (polled in the background); the
/// section quietly omits itself when GitHub isn't configured so the
/// layout doesn't reserve empty real estate.
struct PullRequestsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var manager = PullRequestManager.shared
    @ObservedObject private var config = GitHubConfigStore.shared

    var body: some View {
        if config.isConfigured {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OPEN PRs")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    if !manager.pullRequests.isEmpty {
                        Text("\(manager.pullRequests.count)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                if let error = manager.lastError, manager.pullRequests.isEmpty {
                    Text(error)
                        .monitorFont(size: 10)
                        .foregroundColor(.red.opacity(0.6))
                        .lineLimit(2)
                } else if manager.pullRequests.isEmpty {
                    Text(manager.isLoading ? "Loading…" : "No open PRs")
                        .monitorFont(size: 11)
                        .foregroundColor(.gray.opacity(0.4))
                } else {
                    ForEach(manager.pullRequests) { pr in
                        PullRequestRow(pr: pr, accentColor: appState.accentColor)
                    }
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    let pr: PullRequest
    let accentColor: Color

    var body: some View {
        Button(action: openPR) {
            HStack(alignment: .top, spacing: 8) {
                MergeStatusDot(status: pr.mergeStatus)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .monitorFont(size: 12)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("\(pr.repoFullName)#\(pr.number)")
                            .monitorFont(size: 10)
                            .foregroundColor(accentColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if pr.openCommentThreads > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 9))
                                Text("\(pr.openCommentThreads)")
                                    .monitorFont(size: 9)
                            }
                            .foregroundColor(.gray.opacity(0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    private func openPR() {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MergeStatusDot: View {
    let status: PRMergeStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(tooltip)
    }

    private var color: Color {
        switch status {
        case .ready:         return Color(hex: "6BFF8E")    // green
        case .behind:        return Color(hex: "FFD06B")    // yellow
        case .checksFailing: return Color(hex: "FFD06B")    // yellow
        case .blocked:       return Color(hex: "FF6B6B")    // red
        case .conflicts:     return Color(hex: "FF6B6B")    // red
        case .unknown:       return Color.gray.opacity(0.4)
        }
    }

    private var tooltip: String {
        switch status {
        case .ready:         return "Ready to merge"
        case .behind:        return "Behind base — needs rebase or merge"
        case .checksFailing: return "Checks failing"
        case .blocked:       return "Blocked — protections or required reviews not satisfied"
        case .conflicts:     return "Merge conflicts"
        case .unknown:       return "GitHub hasn't computed merge status yet"
        }
    }
}

/// Companion to PullRequestsSection. Lists every pipeline the user
/// has added to `GitHubConfigStore.pipelineURLs`, each row showing
/// the workflow name plus job counts for the most recent run.
/// Section header has a "+" button that opens a popover suggesting
/// pipelines derived from the latest workflow run of each open PR.
struct PipelinesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var monitor = WorkflowMonitor.shared
    @ObservedObject private var prManager = PullRequestManager.shared
    @ObservedObject private var config = GitHubConfigStore.shared
    @State private var showSuggestions = false

    var body: some View {
        if !config.token.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PIPELINES")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    if !monitor.pipelines.isEmpty {
                        Text("\(monitor.pipelines.count)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                    Button(action: { showSuggestions = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(appState.accentColor)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .help("Add a pipeline from your open PRs")
                    .popover(isPresented: $showSuggestions) {
                        PipelineSuggestionsPopover(
                            prs: prManager.pullRequests,
                            existingIDs: Set(config.parsedPipelines.map(\.id)),
                            accentColor: appState.accentColor,
                            onAdd: { url in
                                var current = config.pipelineURLs
                                current.append(url)
                                config.pipelineURLs = current
                                WorkflowMonitor.shared.refresh()
                            }
                        )
                    }
                }
                if let error = monitor.lastError, monitor.pipelines.isEmpty {
                    Text(error)
                        .monitorFont(size: 10)
                        .foregroundColor(.red.opacity(0.6))
                        .lineLimit(2)
                } else if monitor.pipelines.isEmpty {
                    if config.parsedPipelines.isEmpty {
                        Text("Click + to add a pipeline from your open PRs")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.4))
                    } else {
                        Text(monitor.isLoading ? "Loading…" : "No data")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                } else {
                    ForEach(monitor.pipelines) { p in
                        PipelineRow(status: p,
                                    accentColor: appState.accentColor,
                                    onRemove: {
                                        config.removePipeline(p.spec)
                                        WorkflowMonitor.shared.refresh()
                                    })
                    }
                }
            }
        }
    }
}

private struct PipelineRow: View {
    let status: PipelineStatus
    let accentColor: Color
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openRun) {
                HStack(alignment: .top, spacing: 8) {
                    PipelineStatusDot(overall: status.overall)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.spec.displayName)
                            .monitorFont(size: 12)
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            Text(secondaryLine)
                                .monitorFont(size: 10)
                                .foregroundColor(accentColor.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            countsBadges
                                // Reserve room so the badges don't jump
                                // when the × button slides in on hover.
                                .padding(.trailing, hovering ? 16 : 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cornerRadius(3)
            }
            .buttonStyle(.plain)

            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray.opacity(0.8))
                        .padding(4)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop tracking this pipeline")
                .padding(.top, 4)
                .padding(.trailing, 6)
            }
        }
        .onHover { hovering = $0 }
    }

    /// `owner/repo · branch-name #123` — branch elided only when the
    /// API hasn't told us one yet (no run resolved). Always shown when
    /// available, even on main/master, since the run number alone
    /// isn't enough to distinguish two `.run(id)` pipelines at a glance.
    private var secondaryLine: String {
        var parts: [String] = [status.spec.fullName]
        if let b = status.headBranch, !b.isEmpty {
            parts.append(b)
        }
        var line = parts.joined(separator: " · ")
        if let n = status.runNumber { line += " #\(n)" }
        return line
    }

    /// Per-bucket counts only — suppress zeros so the row stays clean
    /// when the pipeline is just `OK / N succeeded` with no other state.
    @ViewBuilder
    private var countsBadges: some View {
        HStack(spacing: 5) {
            if status.failed > 0 {
                countBadge("xmark", status.failed, color: Color(hex: "FF6B6B"))
            }
            if status.inProgress > 0 {
                countBadge("arrow.triangle.2.circlepath", status.inProgress,
                           color: Color(hex: "66CCFF"))
            }
            if status.queued > 0 {
                countBadge("hourglass", status.queued, color: Color(hex: "FFD06B"))
            }
            if status.succeeded > 0 {
                countBadge("checkmark", status.succeeded, color: Color(hex: "6BFF8E"))
            }
            if status.skipped > 0 {
                countBadge("forward", status.skipped, color: .gray.opacity(0.5))
            }
        }
    }

    private func countBadge(_ symbol: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8))
            Text("\(count)")
                .monitorFont(size: 9)
        }
        .foregroundColor(color)
    }

    private func openRun() {
        if let s = status.runURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        else if let url = URL(string: status.spec.url) { NSWorkspace.shared.open(url) }
    }
}

private struct PipelineStatusDot: View {
    let overall: PipelineOverallStatus
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).help(tooltip)
    }
    private var color: Color {
        switch overall {
        case .running:  return Color(hex: "66CCFF")
        case .success:  return Color(hex: "6BFF8E")
        case .failure:  return Color(hex: "FF6B6B")
        case .mixed:    return Color(hex: "FFD06B")
        case .queued:   return Color(hex: "FFD06B")
        case .skipped:  return Color.gray.opacity(0.5)
        case .unknown:  return Color.gray.opacity(0.4)
        }
    }
    private var tooltip: String {
        switch overall {
        case .running:  return "Pipeline running"
        case .success:  return "All jobs passed"
        case .failure:  return "Failed"
        case .mixed:    return "Some failures, some successes"
        case .queued:   return "Queued — hasn't started"
        case .skipped:  return "Skipped"
        case .unknown:  return "No run data yet"
        }
    }
}

/// Popover content for the "+" button. Surfaces one suggestion per
/// (open PR, workflow that ran on its head branch) — typically up to
/// `numPRs × numWorkflowsPerPR` rows. Filters out any suggestion the
/// user has already added.
private struct PipelineSuggestionsPopover: View {
    let prs: [PullRequest]
    let existingIDs: Set<String>
    let accentColor: Color
    let onAdd: (String) -> Void
    @State private var manualURL: String = ""
    @State private var suggestions: [WorkflowMonitor.Suggestion] = []
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    /// The filtered list — drops suggestions the user already added,
    /// matched by the parsed PipelineSpec id.
    private var visibleSuggestions: [WorkflowMonitor.Suggestion] {
        suggestions.filter { s in
            guard let parsed = PipelineSpec.parse(s.url) else { return true }
            return !existingIDs.contains(parsed.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD PIPELINE")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)
            HStack(spacing: 6) {
                TextField("Paste workflow or run URL", text: $manualURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
                Button("Add") {
                    let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, PipelineSpec.parse(trimmed) != nil {
                        onAdd(trimmed); manualURL = ""; dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Divider().background(Color.white.opacity(0.06))
            Text("FROM OPEN PRs")
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
            if loading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).colorScheme(.dark)
                    Text("Looking up pipelines for each open PR…")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.5))
                }
            } else if visibleSuggestions.isEmpty {
                Text(suggestions.isEmpty
                     ? "No workflow runs found on any open PR head branch."
                     : "All of these are already being tracked.")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                // Up to ~10 rows visible at once; scrolls beyond that.
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleSuggestions) { s in
                            SuggestionRow(suggestion: s,
                                          accentColor: accentColor,
                                          onAdd: {
                                              onAdd(s.url)
                                          })
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(14)
        .frame(width: 420)
        .onAppear { loadSuggestions() }
    }

    private func loadSuggestions() {
        loading = true
        WorkflowMonitor.shared.fetchSuggestions(for: prs) { results in
            suggestions = results
            loading = false
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: WorkflowMonitor.Suggestion
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Dot reflecting the LAST run's conclusion — gives a hint of
            // whether this pipeline is currently green/red without
            // having to click in.
            Circle().fill(conclusionColor)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(suggestion.workflowName)
                        .monitorFont(size: 11)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(suggestion.workflowFile)
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.4))
                        .lineLimit(1)
                }
                Text("\(suggestion.pr.repoFullName)#\(suggestion.pr.number)  ·  \(suggestion.branch)")
                    .monitorFont(size: 9)
                    .foregroundColor(accentColor.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Add") { onAdd() }
                .buttonStyle(.plain)
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .cornerRadius(3)
        }
        .padding(.vertical, 2)
    }

    private var conclusionColor: Color {
        switch suggestion.mostRecentConclusion {
        case "success": return Color(hex: "6BFF8E")
        case "failure", "timed_out", "cancelled", "action_required":
            return Color(hex: "FF6B6B")
        case "skipped": return Color.gray.opacity(0.5)
        case nil: return Color(hex: "66CCFF")   // in progress
        default: return Color.gray.opacity(0.4)
        }
    }
}

struct RemindersSection: View {
    @ObservedObject var appState: AppState
    @StateObject private var reminders = RemindersManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(reminders.displayName)
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                let total = reminders.totalCount
                if total > 0 {
                    Text("\(total)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            if !reminders.accessGranted {
                Text("Reminders access not granted")
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.4))
            } else if reminders.isMultiList {
                // Grouped display: single column. We used to lay out
                // two columns when the section had the full overlay
                // width, but the overlay now reserves the right half
                // for Open PRs / Pipelines so reminders only get the
                // left half — not enough room for two columns of titles.
                let nonEmpty = reminders.groupedReminders.filter { !$0.reminders.isEmpty }
                if nonEmpty.isEmpty {
                    Text(reminders.emptyMessage)
                        .monitorFont(size: 11)
                        .foregroundColor(.gray.opacity(0.3))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(nonEmpty, id: \.id) { group in
                            ReminderListColumn(group: group, appState: appState, reminders: reminders)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if reminders.reminders.isEmpty {
                Text(reminders.emptyMessage)
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Single list or Today: flat display
                let visible = Array(reminders.reminders.prefix(14))
                ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                    ReminderRow(reminder: reminder, appState: appState, manager: reminders)
                }
                if reminders.reminders.count > 14 {
                    Text("+\(reminders.reminders.count - 14) more")
                        .monitorFont(size: 10)
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
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(appState.accentColor.opacity(0.6))
                .tracking(1)

            let visible = Array(group.reminders.prefix(14))
            ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                ReminderRow(reminder: reminder, appState: appState, manager: reminders)
            }
            if group.reminders.count > 14 {
                Text("+\(group.reminders.count - 14) more")
                    .monitorFont(size: 10)
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
                    .monitorFont(size: 12, design: .default)
                    .foregroundColor(reminder.isCompleted ? appState.accentColor : .gray.opacity(0.4))
            }
            .buttonStyle(.plain)

            Text(reminder.title ?? "Untitled")
                .monitorFont(size: 12)
                .foregroundColor(reminder.isCompleted ? .gray.opacity(0.3) : .white.opacity(0.8))
                .strikethrough(reminder.isCompleted)
                .lineLimit(1)

            Spacer()

            if let due = reminder.dueDateComponents, let hour = due.hour, let minute = due.minute {
                let isOverdue = isReminderOverdue(due)
                Text(String(format: "%d:%02d", hour, minute))
                    .monitorFont(size: 10)
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
