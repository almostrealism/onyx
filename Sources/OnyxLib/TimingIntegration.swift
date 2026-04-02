import Foundation
import Combine
import SwiftUI

// MARK: - Shared Timing Data Store

/// Singleton that owns the API token, project list, and raw report data.
/// All windows read from this; each window applies its own project filter.
public class TimingDataStore: ObservableObject {
    public static let shared = TimingDataStore()

    @Published public var availableProjects: [TimingProject] = []
    @Published public var rawRows: [ReportRow] = []
    @Published public var isLoading = false
    @Published public var lastError: String?
    @Published public var weekMonday: Date = Date()

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300

    public struct ReportRow {
        public let date: String       // "2026-04-01"
        public let projectRef: String // "/projects/123" or ""
        public let projectTitle: String
        public let projectColor: String // 6-char hex or ""
        public let parentRef: String?
        public let titleChain: [String]
        public let seconds: Double
    }

    private init() {}

    public var apiToken: String {
        get { UserDefaults.standard.string(forKey: "timing_api_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_api_token")
            objectWillChange.send()
            if !newValue.isEmpty {
                print("Timing: token set, fetching...")
                if timer == nil { startPolling() } else { fetchProjects(); fetchReport() }
            }
        }
    }

    public var isConfigured: Bool { !apiToken.isEmpty }

    public func startPolling() {
        guard isConfigured else {
            print("Timing: not configured")
            return
        }
        guard timer == nil else { return } // already running
        print("Timing: starting shared polling")
        fetchProjects()
        fetchReport()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetchReport()
        }
    }

    // MARK: - Projects

    private func fetchProjects() {
        guard isConfigured else { return }
        var request = URLRequest(url: URL(string: "https://web.timingapp.com/api/v1/projects/hierarchy")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["data"] as? [[String: Any]] else {
                print("Timing: failed to fetch projects")
                return
            }
            var result: [TimingProject] = []
            Self.flattenProjects(projects, depth: 0, into: &result)
            DispatchQueue.main.async {
                self?.availableProjects = result
                print("Timing: loaded \(result.count) projects")
            }
        }.resume()
    }

    private static func flattenProjects(_ projects: [[String: Any]], depth: Int, into result: inout [TimingProject]) {
        for proj in projects {
            guard let selfRef = proj["self"] as? String,
                  let title = proj["title"] as? String else { continue }
            let titleChain = proj["title_chain"] as? [String] ?? [title]
            let rawColor = (proj["color"] as? String ?? "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
            let color = rawColor.count == 6 ? rawColor : ""
            let parent = proj["parent"] as? String

            result.append(TimingProject(id: selfRef, title: title, titleChain: titleChain,
                                        color: color, parentID: parent, depth: depth))
            if let children = proj["children"] as? [[String: Any]] {
                flattenProjects(children, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: - Report

    private func fetchReport() {
        guard isConfigured else { return }
        isLoading = true

        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let sunday = calendar.date(byAdding: .day, value: 6 - daysFromMonday, to: today)!
        weekMonday = monday

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var components = URLComponents(string: "https://web.timingapp.com/api/v1/report")!
        components.queryItems = [
            URLQueryItem(name: "start_date_min", value: df.string(from: monday)),
            URLQueryItem(name: "start_date_max", value: df.string(from: sunday)),
            URLQueryItem(name: "timespan_grouping_mode", value: "day"),
            URLQueryItem(name: "columns[]", value: "timespan"),
            URLQueryItem(name: "columns[]", value: "project"),
            URLQueryItem(name: "include_project_data", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        print("Timing: fetching report...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.lastError = error.localizedDescription; return
                }
                guard let data = data else { self.lastError = "No data"; return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.lastError = "HTTP \(http.statusCode)"; return
                }

                self.lastError = nil
                self.parseReport(data)
            }
        }.resume()
    }

    private func parseReport(_ data: Data) {
        let jsonRows: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            jsonRows = arr
        } else if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = wrapper["data"] as? [[String: Any]] {
            jsonRows = arr
        } else {
            lastError = "Parse error"; return
        }

        var rows: [ReportRow] = []
        for row in jsonRows {
            let duration = (row["duration"] as? Double) ?? (row["duration"] as? Int).map(Double.init) ?? 0
            guard duration > 0 else { continue }

            var dateStr = ""
            if let ts = row["timespan"] as? [String: Any], let s = ts["start_date"] as? String {
                dateStr = String(s.prefix(10))
            }
            guard !dateStr.isEmpty else { continue }

            var title = "(no project)"
            var color = ""
            var selfRef = ""
            var parentRef: String? = nil
            var titleChain: [String] = []

            if let proj = row["project"] as? [String: Any] {
                title = proj["title"] as? String ?? "(no project)"
                selfRef = proj["self"] as? String ?? ""
                parentRef = proj["parent"] as? String
                titleChain = proj["title_chain"] as? [String] ?? [title]
                let rawColor = (proj["color"] as? String ?? "").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                color = rawColor.count == 6 ? rawColor : ""
            }

            rows.append(ReportRow(date: dateStr, projectRef: selfRef, projectTitle: title,
                                  projectColor: color, parentRef: parentRef,
                                  titleChain: titleChain, seconds: duration))
        }

        rawRows = rows
        print("Timing: \(rows.count) report rows")
    }
}

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

// MARK: - Project Model

public struct TimingProject: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let titleChain: [String]
    public let color: String
    public let parentID: String?
    public let depth: Int

    public var displayName: String { titleChain.joined(separator: " > ") }
}
