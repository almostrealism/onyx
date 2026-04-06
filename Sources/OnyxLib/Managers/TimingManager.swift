import Foundation
import Combine

// MARK: - Per-Window Timing Manager

/// Per-window view model that applies a project filter to the shared data.
public class TimingManager: ObservableObject {
    @Published public var dailyHours: [DailyTime] = []
    @Published public var projectTotals: [ProjectTotal] = []
    @Published public var totalWeekHours: Double = 0

    private var storeCancellable: AnyCancellable?
    private let windowIndex: Int

    public struct DailyTime: Identifiable {
        public let id: String
        public let dayLabel: String
        public let date: Date
        public let hours: Double
        public let projects: [ProjectSlice]
    }

    public struct ProjectSlice: Identifiable {
        public var id: String { projectTitle }
        public let projectTitle: String
        public let color: String
        public let hours: Double
    }

    public struct ProjectTotal: Identifiable {
        public var id: String { title }
        public let title: String
        public let color: String
        public let hours: Double
    }

    public init(windowIndex: Int) {
        self.windowIndex = windowIndex
        storeCancellable = TimingDataStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }
    }

    // MARK: - Per-window filter

    public var filterProjectID: String {
        get { UserDefaults.standard.string(forKey: "timing_filter_\(windowIndex)") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_filter_\(windowIndex)")
            objectWillChange.send()
            recompute()
        }
    }

    // MARK: - Convenience accessors for shared state

    public var isConfigured: Bool { TimingDataStore.shared.isConfigured }
    public var isLoading: Bool { TimingDataStore.shared.isLoading }
    public var lastError: String? { TimingDataStore.shared.lastError }
    public var availableProjects: [TimingProject] { TimingDataStore.shared.availableProjects }
    public var apiToken: String {
        get { TimingDataStore.shared.apiToken }
        set { TimingDataStore.shared.apiToken = newValue }
    }

    public var filterProjectName: String {
        if filterProjectID.isEmpty { return "All" }
        return availableProjects.first(where: { $0.id == filterProjectID })?.title ?? filterProjectID
    }

    // MARK: - Recompute filtered view

    public func recompute() {
        let store = TimingDataStore.shared
        let filterID = filterProjectID
        let palette = ["66CCFF", "6BFF8E", "FFD06B", "C06BFF", "FF6B6B", "FF6BCD", "6BFFD0", "FFB86B"]

        let rows: [TimingDataStore.ReportRow]
        if filterID.isEmpty {
            rows = store.rawRows
        } else {
            // Include rows that are the filter project or descendants
            rows = store.rawRows.filter { row in
                if row.projectRef == filterID { return true }
                // Check if any ancestor is the filter project
                var ref = row.parentRef
                while let r = ref {
                    if r == filterID { return true }
                    ref = store.availableProjects.first(where: { $0.id == r })?.parentID
                }
                return false
            }
        }

        // Determine display name for each row
        let filterDepth = store.availableProjects.first(where: { $0.id == filterID })?.depth
        let filterTitle = store.availableProjects.first(where: { $0.id == filterID })?.title ?? ""

        struct Entry {
            let date: String; let project: String; let color: String; let seconds: Double
        }

        var entries: [Entry] = []
        for row in rows {
            var displayTitle = row.projectTitle
            var displayColor = row.projectColor

            if !filterID.isEmpty {
                if row.projectRef == filterID {
                    displayTitle = filterTitle
                } else if let fd = filterDepth, row.titleChain.count > fd + 1 {
                    // Roll up to direct child of filter project
                    displayTitle = row.titleChain[fd + 1]
                    if let child = store.availableProjects.first(where: { $0.title == displayTitle && $0.depth == fd + 1 }) {
                        if !child.color.isEmpty { displayColor = child.color }
                    }
                }
            }

            entries.append(Entry(date: row.date, project: displayTitle, color: displayColor, seconds: row.seconds))
        }

        // Aggregate
        var byDateProject: [String: [String: (color: String, seconds: Double)]] = [:]
        var projectTotalMap: [String: (color: String, seconds: Double)] = [:]

        for e in entries {
            byDateProject[e.date, default: [:]][e.project, default: (e.color, 0)].seconds += e.seconds
            projectTotalMap[e.project, default: (e.color, 0)].seconds += e.seconds
        }

        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let monday = store.weekMonday

        var daily: [DailyTime] = []
        var total: Double = 0

        for i in 0..<7 {
            let date = calendar.date(byAdding: .day, value: i, to: monday)!
            let dateStr = df.string(from: date)
            let dayProjects = byDateProject[dateStr] ?? [:]
            let dayTotal = dayProjects.values.reduce(0.0) { $0 + $1.seconds }
            let hours = dayTotal / 3600.0
            total += hours

            let slices = dayProjects.map { entry -> ProjectSlice in
                var color = entry.value.color
                if color.isEmpty || color.count != 6 {
                    color = palette[abs(entry.key.hashValue) % palette.count]
                }
                return ProjectSlice(projectTitle: entry.key, color: color, hours: entry.value.seconds / 3600.0)
            }.sorted { $0.hours > $1.hours }

            daily.append(DailyTime(id: dayLabels[i], dayLabel: dayLabels[i], date: date, hours: hours, projects: slices))
        }

        var colorIndex = 0
        let totals = projectTotalMap.map { entry -> ProjectTotal in
            var color = entry.value.color
            if color.isEmpty || color.count != 6 {
                color = palette[colorIndex % palette.count]
                colorIndex += 1
            }
            return ProjectTotal(title: entry.key, color: color, hours: entry.value.seconds / 3600.0)
        }.sorted { $0.hours > $1.hours }

        dailyHours = daily
        projectTotals = totals
        totalWeekHours = total
    }
}
