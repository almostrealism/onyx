//
// TimingDataStore.swift
//
// Responsibility: Owns the Timing.app API token, project list, raw report
//                 rows, and the current week boundary; refreshes from the
//                 Timing API on a 5-minute timer.
// Scope: Shared singleton (TimingDataStore.shared); per-window TimingManager
//        instances subscribe and apply their own project filters.
// Threading: Timer fires on main; URL fetches use URLSession completion
//            handlers and dispatch back to main before mutating state.
// Invariants:
//   - apiToken is stored in UserDefaults; setting an empty token is allowed
//     but isConfigured returns false
//   - timer is non-nil iff polling is active; startPolling is idempotent
//   - rawRows always corresponds to the week beginning weekMonday
//

import Foundation
import Combine

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
            let color = rawColor.count >= 6 ? String(rawColor.prefix(6)) : ""
            let parent: String? = {
                if let s = proj["parent"] as? String { return s }
                if let obj = proj["parent"] as? [String: Any] { return obj["self"] as? String }
                return nil
            }()

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
        // Set timezone so date-only values are interpreted in local time, not UTC
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Time-Zone")
        request.timeoutInterval = 15

        print("Timing: fetching report (tz: \(TimeZone.current.identifier))...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.lastError = error.localizedDescription; return
                }
                guard let data = data else { self.lastError = "No data"; return }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("Timing: HTTP \(http.statusCode): \(body.prefix(500))")
                    self.lastError = "HTTP \(http.statusCode): \(body.prefix(80))"
                    return
                }
                print("Timing: HTTP 200, \(data.count) bytes")

                self.lastError = nil
                self.parseReport(data)
            }
        }.resume()
    }

    private func parseReport(_ data: Data) {
        let preview = String(data: data, encoding: .utf8)?.prefix(300) ?? "nil"
        print("Timing: response preview: \(preview)")

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
            // start_date is a top-level field; timespan is a display string, not an object
            if let s = row["start_date"] as? String {
                dateStr = String(s.prefix(10))
            } else if let ts = row["timespan"] as? [String: Any], let s = ts["start_date"] as? String {
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
                // parent is either a string ref or an object {"self": "/projects/..."}
                if let parentStr = proj["parent"] as? String {
                    parentRef = parentStr
                } else if let parentObj = proj["parent"] as? [String: Any] {
                    parentRef = parentObj["self"] as? String
                }
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
