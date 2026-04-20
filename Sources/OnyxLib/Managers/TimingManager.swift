//
// TimingManager.swift
//
// Responsibility: Per-window view model over TimingDataStore — applies the
//                 window's project filter and rolls up daily/weekly hours
//                 plus per-project totals for the timing panel.
// Scope: Per-window (lives on AppState); subscribes to the shared store.
// Threading: Main actor — store change notifications are dispatched to main
//            before recompute() runs.
// Invariants:
//   - filterProjectID persists in UserDefaults under the window index key
//   - dailyHours always contains exactly 7 entries (Mon..Sun of weekMonday)
//   - totalWeekHours == sum of dailyHours[*].hours
//   - When filterProjectID is empty, all rows are included; otherwise rows
//     matching the project or any descendant are rolled up to direct children
//

import Foundation
import Combine

// MARK: - Per-Window Timing Manager

/// Per-window view model that applies a project filter to the shared data.
public class TimingManager: ObservableObject {
    @Published public var dailyHours: [DailyTime] = []
    @Published public var projectTotals: [ProjectTotal] = []
    @Published public var totalWeekHours: Double = 0

    /// 24 columns × 7 rows heatmap cells. Column 0 is the oldest week, column
    /// 23 is the current (in-progress) week. Row 0 is Monday, row 6 is Sunday.
    /// Each value is hours on that day, already filtered by the project filter.
    @Published public var heatmap: [[Double]] = []

    /// Average hours/week across the last 4 *completed* weeks, excluding the
    /// current in-progress week. Zero if there's no data.
    @Published public var avgHoursPerWeekLast4: Double = 0

    /// Average hours/day across the last 30 days, excluding today (to avoid a
    /// partial-day reading). Denominator is 30 — days with no data still count,
    /// so this reflects an honest daily average including off-days.
    @Published public var avgHoursPerDayLast30: Double = 0

    /// The Monday that anchors the heatmap's rightmost column (current week).
    @Published public var heatmapAnchorMonday: Date = Date()

    private var storeCancellable: AnyCancellable?
    private let windowIndex: Int

    /// DailyTime.
    public struct DailyTime: Identifiable {
        /// Id.
        public let id: String
        /// Day label.
        public let dayLabel: String
        /// Date.
        public let date: Date
        /// Hours.
        public let hours: Double
        /// Projects.
        public let projects: [ProjectSlice]
    }

    /// ProjectSlice.
    public struct ProjectSlice: Identifiable {
        /// Id.
        public var id: String { projectTitle }
        /// Project title.
        public let projectTitle: String
        /// Color.
        public let color: String
        /// Hours.
        public let hours: Double
    }

    /// ProjectTotal.
    public struct ProjectTotal: Identifiable {
        /// Id.
        public var id: String { title }
        /// Title.
        public let title: String
        /// Color.
        public let color: String
        /// Hours.
        public let hours: Double
    }

    /// Create a new instance.
    public init(windowIndex: Int) {
        self.windowIndex = windowIndex
        storeCancellable = TimingDataStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }
    }

    // MARK: - Per-window filter

    /// Filter project id.
    public var filterProjectID: String {
        get { UserDefaults.standard.string(forKey: "timing_filter_\(windowIndex)") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_filter_\(windowIndex)")
            objectWillChange.send()
            recompute()
        }
    }

    // MARK: - Convenience accessors for shared state

    /// Is configured.
    public var isConfigured: Bool { TimingDataStore.shared.isConfigured }
    /// Is loading.
    public var isLoading: Bool { TimingDataStore.shared.isLoading }
    /// Last error.
    public var lastError: String? { TimingDataStore.shared.lastError }
    /// Available projects.
    public var availableProjects: [TimingProject] { TimingDataStore.shared.availableProjects }
    /// Api token.
    public var apiToken: String {
        get { TimingDataStore.shared.apiToken }
        set { TimingDataStore.shared.apiToken = newValue }
    }

    /// Filter project name.
    public var filterProjectName: String {
        if filterProjectID.isEmpty { return "All" }
        return availableProjects.first(where: { $0.id == filterProjectID })?.title ?? filterProjectID
    }

    // MARK: - Recompute filtered view

    /// Recompute.
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

        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let monday = store.weekMonday

        // Set of date strings for the current week, used to scope the bar
        // chart and the project-totals legend to this week only. The longer
        // trailing averages and the heatmap intentionally use the full
        // 26-week entries list.
        var currentWeekDates = Set<String>()
        for i in 0..<7 {
            let d = calendar.date(byAdding: .day, value: i, to: monday)!
            currentWeekDates.insert(df.string(from: d))
        }

        // Aggregate — project totals and the bar chart must only see
        // current-week entries; projectTotalMap was previously summing
        // the whole 26-week dataset which produced misleading huge numbers.
        var byDateProject: [String: [String: (color: String, seconds: Double)]] = [:]
        var projectTotalMap: [String: (color: String, seconds: Double)] = [:]

        for e in entries where currentWeekDates.contains(e.date) {
            byDateProject[e.date, default: [:]][e.project, default: (e.color, 0)].seconds += e.seconds
            projectTotalMap[e.project, default: (e.color, 0)].seconds += e.seconds
        }

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

        // Build a date → hours map over ALL filtered entries (26 weeks) for
        // the new stats and heatmap. Uses the same entries list we already
        // filtered above.
        var hoursByDate: [String: Double] = [:]
        for e in entries {
            hoursByDate[e.date, default: 0] += e.seconds / 3600.0
        }

        let today = Date()
        heatmapAnchorMonday = monday
        heatmap = Self.buildHeatmap(hoursByDate: hoursByDate, anchorMonday: monday)
        avgHoursPerWeekLast4 = Self.avgHoursPerWeek(hoursByDate: hoursByDate, currentMonday: monday, weeks: 4)
        avgHoursPerDayLast30 = Self.avgHoursPerDay(hoursByDate: hoursByDate, today: today, days: 30)
    }

    // MARK: - Pure helpers (testable without a TimingManager instance)

    /// Number of weeks shown in the heatmap grid.
    public static let heatmapWeeks = 26

    /// Build a heatmap grid of hours. Column 0 is the oldest week, column
    /// (heatmapWeeks-1) is the week starting `anchorMonday`.
    /// Row 0 is Monday, row 6 is Sunday.
    public static func buildHeatmap(hoursByDate: [String: Double], anchorMonday: Date) -> [[Double]] {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var grid: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 7), count: heatmapWeeks)
        for week in 0..<heatmapWeeks {
            let weekStart = calendar.date(byAdding: .day, value: -(heatmapWeeks - 1 - week) * 7, to: anchorMonday)!
            for day in 0..<7 {
                let date = calendar.date(byAdding: .day, value: day, to: weekStart)!
                grid[week][day] = hoursByDate[df.string(from: date)] ?? 0
            }
        }
        return grid
    }

    /// Average hours/week over the N most recent *completed* weeks preceding
    /// `currentMonday` (so the in-progress week is excluded). Denominator is
    /// always `weeks`, so weeks with no data pull the average down.
    public static func avgHoursPerWeek(hoursByDate: [String: Double], currentMonday: Date, weeks: Int) -> Double {
        guard weeks > 0 else { return 0 }
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var total: Double = 0
        for w in 1...weeks {
            let weekStart = calendar.date(byAdding: .day, value: -w * 7, to: currentMonday)!
            for day in 0..<7 {
                let date = calendar.date(byAdding: .day, value: day, to: weekStart)!
                total += hoursByDate[df.string(from: date)] ?? 0
            }
        }
        return total / Double(weeks)
    }

    /// Average hours/day over the N days preceding `today` (today itself is
    /// excluded). Denominator is always `days`.
    public static func avgHoursPerDay(hoursByDate: [String: Double], today: Date, days: Int) -> Double {
        guard days > 0 else { return 0 }
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var total: Double = 0
        for d in 1...days {
            let date = calendar.date(byAdding: .day, value: -d, to: today)!
            total += hoursByDate[df.string(from: date)] ?? 0
        }
        return total / Double(days)
    }
}
