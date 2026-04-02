import Foundation
import Combine
import SwiftUI

/// Integration with Timing.app (https://timingapp.com) for time tracking display.
public class TimingManager: ObservableObject {
    @Published public var dailyHours: [DailyTime] = []
    @Published public var projectTotals: [ProjectTotal] = []
    @Published public var totalWeekHours: Double = 0
    @Published public var isLoading = false
    @Published public var lastError: String?
    @Published public var isConfigured: Bool = false
    @Published public var availableProjects: [TimingProject] = []

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300

    public struct DailyTime: Identifiable {
        public let id: String
        public let dayLabel: String
        public let date: Date
        public let hours: Double
        /// Per-project breakdown for this day
        public let projects: [ProjectSlice]
    }

    public struct ProjectSlice: Identifiable {
        public var id: String { projectTitle }
        public let projectTitle: String
        public let color: String // hex
        public let hours: Double
    }

    public struct ProjectTotal: Identifiable {
        public var id: String { title }
        public let title: String
        public let color: String
        public let hours: Double
    }

    public struct TimingProject: Identifiable, Hashable {
        public let id: String        // "/projects/123"
        public let title: String
        public let titleChain: [String]
        public let color: String
        public let parentID: String?
        public let depth: Int

        public var displayName: String {
            titleChain.joined(separator: " > ")
        }
    }

    public init() {}

    public func checkConfiguration() {
        isConfigured = !apiToken.isEmpty
    }

    public func startPolling() {
        checkConfiguration()
        guard isConfigured else {
            print("Timing: not configured")
            return
        }
        print("Timing: starting polling")
        fetchProjects()
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        guard isConfigured else { return }
        fetch()
    }

    // MARK: - Configuration

    public var apiToken: String {
        get { UserDefaults.standard.string(forKey: "timing_api_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_api_token")
            isConfigured = !newValue.isEmpty
            if isConfigured {
                print("Timing: token set, fetching...")
                if timer == nil { startPolling() } else { fetchProjects(); fetch() }
            }
        }
    }

    /// Selected project filter ID (e.g. "/projects/123"). Empty = all projects.
    public var filterProjectID: String {
        get { UserDefaults.standard.string(forKey: "timing_filter_project") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_filter_project")
            objectWillChange.send()
            fetch()
        }
    }

    public var filterProjectName: String {
        if filterProjectID.isEmpty { return "All" }
        return availableProjects.first(where: { $0.id == filterProjectID })?.title ?? filterProjectID
    }

    // MARK: - Projects API

    private func fetchProjects() {
        guard !apiToken.isEmpty else { return }

        var request = URLRequest(url: URL(string: "https://web.timingapp.com/api/v1/projects/hierarchy")!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
            let color = proj["color"] as? String ?? "66CCFF"
            let parent = proj["parent"] as? String

            result.append(TimingProject(
                id: selfRef,
                title: title,
                titleChain: titleChain,
                color: color.replacingOccurrences(of: "#", with: ""),
                parentID: parent,
                depth: depth
            ))

            if let children = proj["children"] as? [[String: Any]] {
                flattenProjects(children, depth: depth + 1, into: &result)
            }
        }
    }

    // MARK: - Report API

    private func fetch() {
        guard !apiToken.isEmpty else { return }
        isLoading = true

        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let sunday = calendar.date(byAdding: .day, value: 6 - daysFromMonday, to: today)!

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        var queryItems = [
            URLQueryItem(name: "start_date_min", value: df.string(from: monday)),
            URLQueryItem(name: "start_date_max", value: df.string(from: sunday)),
            URLQueryItem(name: "timespan_grouping_mode", value: "day"),
            URLQueryItem(name: "columns[]", value: "timespan"),
            URLQueryItem(name: "columns[]", value: "project"),
            URLQueryItem(name: "include_project_data", value: "1"),
        ]

        if !filterProjectID.isEmpty {
            queryItems.append(URLQueryItem(name: "projects[]", value: filterProjectID))
            queryItems.append(URLQueryItem(name: "include_child_projects", value: "1"))
        }

        var components = URLComponents(string: "https://web.timingapp.com/api/v1/report")!
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        print("Timing: GET \(components.url?.absoluteString.prefix(120) ?? "?")")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    print("Timing: error: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    return
                }
                guard let data = data else {
                    self.lastError = "No data"
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("Timing: HTTP \(http.statusCode): \(body.prefix(200))")
                    self.lastError = "HTTP \(http.statusCode)"
                    return
                }

                self.lastError = nil
                self.parseResponse(data, monday: monday)
            }
        }.resume()
    }

    private func parseResponse(_ data: Data, monday: Date) {
        let rows: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = arr
        } else if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = wrapper["data"] as? [[String: Any]] {
            rows = arr
        } else {
            print("Timing: failed to parse response")
            lastError = "Parse error"
            return
        }

        print("Timing: \(rows.count) rows")

        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        // Parse rows into (date, projectTitle, projectColor, seconds)
        struct Entry {
            let date: String
            let project: String
            let color: String
            let seconds: Double
        }

        let filterID = filterProjectID
        var entries: [Entry] = []

        for row in rows {
            let duration = (row["duration"] as? Double) ?? (row["duration"] as? Int).map(Double.init) ?? 0
            guard duration > 0 else { continue }

            var dateStr = ""
            if let ts = row["timespan"] as? [String: Any], let s = ts["start_date"] as? String {
                dateStr = String(s.prefix(10))
            } else if let s = row["start_date"] as? String {
                dateStr = String(s.prefix(10))
            }
            guard !dateStr.isEmpty else { continue }

            var projectTitle = "(no project)"
            var projectColor = "888888"
            if let proj = row["project"] as? [String: Any] {
                projectTitle = proj["title"] as? String ?? "(no project)"
                projectColor = (proj["color"] as? String ?? "888888").replacingOccurrences(of: "#", with: "")

                // If filtering, determine the display name:
                // - Direct children of filter project → show their title
                // - The filter project itself (time not in subproject) → show "filterName"
                if !filterID.isEmpty, let selfRef = proj["self"] as? String {
                    let parent = proj["parent"] as? String
                    if selfRef == filterID {
                        // Time on the parent project itself
                        projectTitle = filterProjectName
                    } else if parent != filterID {
                        // Deeper child — roll up to direct child
                        if let chain = proj["title_chain"] as? [String] {
                            let filterDepth = availableProjects.first(where: { $0.id == filterID })?.depth ?? 0
                            if chain.count > filterDepth + 1 {
                                projectTitle = chain[filterDepth + 1]
                                // Find color from the direct child
                                if let directChild = availableProjects.first(where: { $0.title == projectTitle && $0.depth == filterDepth + 1 }) {
                                    projectColor = directChild.color
                                }
                            }
                        }
                    }
                }
            }

            entries.append(Entry(date: dateStr, project: projectTitle, color: projectColor, seconds: duration))
        }

        // Aggregate by date and project
        var byDateProject: [String: [String: (color: String, seconds: Double)]] = [:]
        var projectTotalMap: [String: (color: String, seconds: Double)] = [:]

        for e in entries {
            byDateProject[e.date, default: [:]][e.project, default: (e.color, 0)].seconds += e.seconds
            projectTotalMap[e.project, default: (e.color, 0)].seconds += e.seconds
        }

        // Build daily hours
        var daily: [DailyTime] = []
        var total: Double = 0

        for i in 0..<7 {
            let date = calendar.date(byAdding: .day, value: i, to: monday)!
            let dateStr = df.string(from: date)
            let dayProjects = byDateProject[dateStr] ?? [:]
            let dayTotal = dayProjects.values.reduce(0.0) { $0 + $1.seconds }
            let hours = dayTotal / 3600.0
            total += hours

            let slices = dayProjects.map { ProjectSlice(projectTitle: $0.key, color: $0.value.color, hours: $0.value.seconds / 3600.0) }
                .sorted { $0.hours > $1.hours }

            daily.append(DailyTime(
                id: dayLabels[i],
                dayLabel: dayLabels[i],
                date: date,
                hours: hours,
                projects: slices
            ))
        }

        let totals = projectTotalMap.map { ProjectTotal(title: $0.key, color: $0.value.color, hours: $0.value.seconds / 3600.0) }
            .sorted { $0.hours > $1.hours }

        dailyHours = daily
        projectTotals = totals
        totalWeekHours = total
        print("Timing: total=\(String(format: "%.1f", total))h, \(totals.count) projects")
    }
}
