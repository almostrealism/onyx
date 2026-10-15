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
//   - filterProjectIDs (up to `maxFilterProjects`, in the order chosen)
//     persists in UserDefaults under the window index key
//   - `groups` has one entry per selected project, in that order — or a
//     single "All" group when none is selected
//   - every group's dailyHours has exactly 7 entries (Mon..Sun of weekMonday)
//   - the combined properties (dailyHours, projectTotals, totalWeekHours,
//     heatmap, averages) cover every selected project together
//   - Rows under a selected project are rolled up to its direct children;
//     time logged to the project itself keeps the project's own name
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
    @Published public var heatmapAnchorMonday = Date()

    /// One set of bars and numbers per selected top-level project, in the
    /// order they were chosen — or a single "All" group when none is.
    @Published public var groups: [TimingGroup] = []

    /// The most top-level projects that can be selected at once. Each gets
    /// its own bar per day, so three means 21 bars in the week chart —
    /// past that they stop being readable.
    public static let maxFilterProjects = 3

    private var storeCancellable: AnyCancellable?
    private let windowIndex: Int

    /// DailyTime.
    /// Reorder every day's slice list using the week-total ranking so
    /// each bar in the daily-hours chart stacks projects in the same
    /// order. The view renders the slice array top-to-bottom, so we
    /// sort smallest-weekly-total → largest, which means the largest
    /// weekly-total project lands at the BOTTOM of every bar. A user
    /// can then visually follow a single colored band across the week
    /// to track that project's daily progression.
    ///
    /// `totals` must be sorted biggest-first (the canonical ordering
    /// `recomputeWeekly` produces); we depend on that for the rank
    /// derivation. Verified by `TimingProjectOrderTests`.
    public static func applyConsistentStackOrder(
        daily: [DailyTime],
        totals: [ProjectTotal]
    ) -> [DailyTime] {
        // Build rank map: biggest weekly total → largest rank value.
        // `totals` is sorted biggest-first, so element at offset 0 gets
        // rank = totals.count, the last element gets rank = 1.
        var weeklyRank: [String: Int] = [:]
        for (offset, t) in totals.enumerated() {
            weeklyRank[t.title] = totals.count - offset
        }
        return daily.map { day in
            let sorted = day.projects.sorted {
                (weeklyRank[$0.projectTitle] ?? 0)
                    < (weeklyRank[$1.projectTitle] ?? 0)
            }
            return DailyTime(id: day.id, dayLabel: day.dayLabel,
                             date: day.date, hours: day.hours,
                             projects: sorted)
        }
    }

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

    /// One selected project's week: its own bars, totals and averages.
    public struct TimingGroup: Identifiable {
        /// The project's id, or "" for the All group.
        public let id: String
        public let title: String
        public let color: String
        public let dailyHours: [DailyTime]
        public let projectTotals: [ProjectTotal]
        public let totalWeekHours: Double
        public let avgHoursPerWeekLast4: Double
        public let avgHoursPerDayLast30: Double

        /// This week's hours over the days that have any — the "/day"
        /// figure. A day off doesn't drag it down mid-week.
        public var perDayThisWeek: Double {
            let days = dailyHours.filter { $0.hours > 0 }.count
            return days > 0 ? totalWeekHours / Double(days) : 0
        }
    }

    /// Create a new instance.
    public init(windowIndex: Int) {
        self.windowIndex = windowIndex
        storeCancellable = TimingDataStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.recompute() }
        }
    }

    // MARK: - Per-window filter

    /// The selected top-level projects, in the order chosen. Empty means
    /// All. Stored as a list; a window that had the old single filter
    /// keeps it as its first entry.
    public var filterProjectIDs: [String] {
        get {
            let defaults = UserDefaults.standard
            if let list = defaults.stringArray(forKey: "timing_filters_\(windowIndex)") {
                return list
            }
            let legacy = defaults.string(forKey: "timing_filter_\(windowIndex)") ?? ""
            return legacy.isEmpty ? [] : [legacy]
        }
        set {
            let list = Array(newValue.prefix(Self.maxFilterProjects))
            UserDefaults.standard.set(list, forKey: "timing_filters_\(windowIndex)")
            objectWillChange.send()
            recompute()
        }
    }

    /// Select or deselect one project. Selecting past the limit is ignored
    /// — Settings dims the rest — rather than silently dropping one the
    /// user chose earlier.
    public func toggleFilterProject(_ id: String) {
        filterProjectIDs = Self.toggled(id, in: filterProjectIDs)
    }

    /// `toggleFilterProject`, as a pure function.
    public static func toggled(_ id: String, in list: [String]) -> [String] {
        if list.contains(id) { return list.filter { $0 != id } }
        guard list.count < maxFilterProjects else { return list }
        return list + [id]
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

    /// Filter project names, in the order chosen.
    public var filterProjectNames: [String] {
        filterProjectIDs.map { id in availableProjects.first(where: { $0.id == id })?.title ?? id }
    }

    // MARK: - Recompute filtered view

    /// Recompute.
    public func recompute() {
        let store = TimingDataStore.shared
        let result = Self.compute(rows: store.rawRows, projects: store.availableProjects,
                                  filterIDs: filterProjectIDs, monday: store.weekMonday,
                                  today: Date())
        groups = result.groups
        dailyHours = result.combined.dailyHours
        projectTotals = result.combined.projectTotals
        totalWeekHours = result.combined.totalWeekHours
        avgHoursPerWeekLast4 = result.combined.avgHoursPerWeekLast4
        avgHoursPerDayLast30 = result.combined.avgHoursPerDayLast30
        heatmapAnchorMonday = store.weekMonday
        heatmap = result.heatmap
    }

    // MARK: - The computation, pure

    private static let palette = ["66CCFF", "6BFF8E", "FFD06B", "C06BFF", "FF6B6B", "FF6BCD", "6BFFD0", "FFB86B"]

    /// A project's color: its own when Timing gives one, else a palette
    /// entry chosen from its name. Stable on purpose — the fallback used
    /// `hashValue`, which Swift seeds per launch, and the bars and the
    /// legend each picked one their own way, so an uncolored project could
    /// be one color in a bar and another beside its legend dot.
    static func color(_ given: String, for title: String) -> String {
        if given.count == 6 { return given }
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }

    struct Entry {
        let date: String
        let project: String
        let color: String
        let seconds: Double
    }

    public struct Computed {
        public let groups: [TimingGroup]
        /// Every selected project together: the legend, the heatmap.
        public let combined: TimingGroup
        public let heatmap: [[Double]]
    }

    /// Everything the timing views show, from the store's raw rows.
    ///
    /// Each selected top-level project becomes a group of its own; rows
    /// under it are rolled up to its direct children, and time logged to
    /// the project itself keeps the project's name. With nothing selected
    /// there is one group, All, with no rollup. The combined group is the
    /// union, and its totals rank every subproject by time regardless of
    /// parent — which is the legend's order, and the stacking order of
    /// every bar in every group, so a band can be followed across the week.
    public static func compute(rows: [TimingDataStore.ReportRow], projects: [TimingProject],
                               filterIDs: [String], monday: Date, today: Date) -> Computed {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Which selected project (if any) a row falls under.
        func owner(of row: TimingDataStore.ReportRow) -> String? {
            if filterIDs.contains(row.projectRef) { return row.projectRef }
            var ref = row.parentRef
            var hops = 0
            while let r = ref, hops < 32 {
                if filterIDs.contains(r) { return r }
                ref = byID[r]?.parentID
                hops += 1
            }
            return nil
        }

        var entriesByGroup: [String: [Entry]] = [:]
        if filterIDs.isEmpty {
            entriesByGroup[""] = rows.map {
                Entry(date: $0.date, project: $0.projectTitle,
                      color: color($0.projectColor, for: $0.projectTitle), seconds: $0.seconds)
            }
        } else {
            for row in rows {
                guard let gid = owner(of: row), let parent = byID[gid] else { continue }
                var title = row.projectTitle
                var hex = row.projectColor
                if row.projectRef == gid {
                    title = parent.title
                } else if row.titleChain.count > parent.depth + 1 {
                    // Roll up to the selected project's direct child.
                    title = row.titleChain[parent.depth + 1]
                    if let child = projects.first(where: {
                        $0.parentID == gid && $0.title == title
                    }), !child.color.isEmpty {
                        hex = child.color
                    }
                }
                entriesByGroup[gid, default: []].append(
                    Entry(date: row.date, project: title, color: color(hex, for: title),
                          seconds: row.seconds))
            }
        }

        let groupIDs = filterIDs.isEmpty ? [""] : filterIDs
        let all = groupIDs.flatMap { entriesByGroup[$0] ?? [] }
        let combinedRaw = summarize(id: "combined", title: "All", color: "66CCFF",
                                    entries: all, monday: monday, today: today)

        // Every bar, in every group, stacks in the combined ranking.
        let groups = groupIDs.map { gid -> TimingGroup in
            let project = byID[gid]
            let g = summarize(id: gid, title: project?.title ?? "All",
                              color: color(project?.color ?? "", for: project?.title ?? "All"),
                              entries: entriesByGroup[gid] ?? [], monday: monday, today: today)
            return TimingGroup(id: g.id, title: g.title, color: g.color,
                               dailyHours: applyConsistentStackOrder(daily: g.dailyHours,
                                                                     totals: combinedRaw.projectTotals),
                               projectTotals: g.projectTotals, totalWeekHours: g.totalWeekHours,
                               avgHoursPerWeekLast4: g.avgHoursPerWeekLast4,
                               avgHoursPerDayLast30: g.avgHoursPerDayLast30)
        }
        let combined = TimingGroup(
            id: combinedRaw.id, title: combinedRaw.title, color: combinedRaw.color,
            dailyHours: applyConsistentStackOrder(daily: combinedRaw.dailyHours,
                                                  totals: combinedRaw.projectTotals),
            projectTotals: combinedRaw.projectTotals, totalWeekHours: combinedRaw.totalWeekHours,
            avgHoursPerWeekLast4: combinedRaw.avgHoursPerWeekLast4,
            avgHoursPerDayLast30: combinedRaw.avgHoursPerDayLast30)

        var hoursByDate: [String: Double] = [:]
        for e in all { hoursByDate[e.date, default: 0] += e.seconds / 3600.0 }
        return Computed(groups: groups, combined: combined,
                        heatmap: buildHeatmap(hoursByDate: hoursByDate, anchorMonday: monday))
    }

    /// One group's week (bars, totals) and longer averages from its entries.
    static func summarize(id: String, title: String, color: String, entries: [Entry],
                          monday: Date, today: Date) -> TimingGroup {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        // The bars and totals are this week only; the averages use the
        // whole history the store holds.
        var weekDates: [String] = []
        for i in 0..<7 {
            weekDates.append(df.string(from: calendar.date(byAdding: .day, value: i, to: monday)!))
        }
        let thisWeek = Set(weekDates)

        var byDateProject: [String: [String: (color: String, seconds: Double)]] = [:]
        var totalsMap: [String: (color: String, seconds: Double)] = [:]
        var hoursByDate: [String: Double] = [:]
        for e in entries {
            hoursByDate[e.date, default: 0] += e.seconds / 3600.0
            guard thisWeek.contains(e.date) else { continue }
            byDateProject[e.date, default: [:]][e.project, default: (e.color, 0)].seconds += e.seconds
            totalsMap[e.project, default: (e.color, 0)].seconds += e.seconds
        }

        var daily: [DailyTime] = []
        var total = 0.0
        for (i, dateStr) in weekDates.enumerated() {
            let day = byDateProject[dateStr] ?? [:]
            let hours = day.values.reduce(0.0) { $0 + $1.seconds } / 3600.0
            total += hours
            let slices = day.map {
                ProjectSlice(projectTitle: $0.key, color: $0.value.color, hours: $0.value.seconds / 3600.0)
            }
            daily.append(DailyTime(id: dayLabels[i], dayLabel: dayLabels[i],
                                   date: calendar.date(byAdding: .day, value: i, to: monday)!,
                                   hours: hours, projects: slices))
        }
        let totals = totalsMap.map {
            ProjectTotal(title: $0.key, color: $0.value.color, hours: $0.value.seconds / 3600.0)
        }
            .sorted { $0.hours != $1.hours ? $0.hours > $1.hours : $0.title < $1.title }

        return TimingGroup(id: id, title: title, color: color,
                           dailyHours: applyConsistentStackOrder(daily: daily, totals: totals),
                           projectTotals: totals, totalWeekHours: total,
                           avgHoursPerWeekLast4: avgHoursPerWeek(hoursByDate: hoursByDate,
                                                                 currentMonday: monday, weeks: 4),
                           avgHoursPerDayLast30: avgHoursPerDay(hoursByDate: hoursByDate,
                                                                today: today, days: 30))
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
