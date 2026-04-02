import Foundation
import Combine

/// Integration with Timing.app (https://timingapp.com) for time tracking display.
/// Fetches weekly time data from the Timing.app web API and displays it on the monitor overlay.
public class TimingManager: ObservableObject {
    @Published public var dailyHours: [DailyTime] = [] // one per day, Mon-Sun
    @Published public var totalWeekHours: Double = 0
    @Published public var isLoading = false
    @Published public var lastError: String?
    @Published public var isConfigured: Bool = false

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // 5 minutes

    public struct DailyTime: Identifiable {
        public let id: String // "Mon", "Tue", etc.
        public let dayLabel: String
        public let date: Date
        public let hours: Double
    }

    public init() {}

    /// Check if an API token is configured
    public func checkConfiguration() {
        isConfigured = !apiToken.isEmpty
    }

    /// Start periodic polling
    public func startPolling() {
        checkConfiguration()
        guard isConfigured else {
            print("Timing: not configured (no API token)")
            return
        }
        print("Timing: starting polling (interval: \(refreshInterval)s)")
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Force a refresh
    public func refresh() {
        guard isConfigured else { return }
        fetch()
    }

    // MARK: - Configuration

    /// The API token, stored in UserDefaults
    public var apiToken: String {
        get { UserDefaults.standard.string(forKey: "timing_api_token") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "timing_api_token")
            isConfigured = !newValue.isEmpty
            if isConfigured {
                print("Timing: token configured, fetching...")
                // Start polling if not already running
                if timer == nil {
                    startPolling()
                } else {
                    fetch()
                }
            }
        }
    }

    // MARK: - API

    private func fetch() {
        guard !apiToken.isEmpty else {
            print("Timing: fetch skipped (no token)")
            return
        }
        isLoading = true
        print("Timing: fetching...")

        // Calculate current week (Monday to today)
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        // .weekday: 1=Sun, 2=Mon, ..., 7=Sat. We want Monday as start.
        let daysFromMonday = (weekday + 5) % 7 // 0=Mon, 1=Tue, ...
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let sunday = calendar.date(byAdding: .day, value: 6 - daysFromMonday, to: today)!

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let startDate = df.string(from: monday)
        let endDate = df.string(from: sunday)

        var components = URLComponents(string: "https://web.timingapp.com/api/v1/report")!
        components.queryItems = [
            URLQueryItem(name: "start_date_min", value: startDate),
            URLQueryItem(name: "start_date_max", value: endDate),
            URLQueryItem(name: "timespan_grouping_mode", value: "day"),
            URLQueryItem(name: "columns[]", value: "timespan"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        print("Timing: GET \(components.url?.absoluteString ?? "?") range=\(startDate)..\(endDate)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    print("Timing: network error: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    return
                }

                guard let data = data else {
                    print("Timing: no data received")
                    self.lastError = "No data received"
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    print("Timing: HTTP \(httpResponse.statusCode), \(data.count) bytes")
                    if httpResponse.statusCode != 200 {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        print("Timing: error body: \(body.prefix(300))")
                        self.lastError = "HTTP \(httpResponse.statusCode): \(body.prefix(100))"
                        return
                    }
                }

                self.lastError = nil
                self.parseResponse(data, monday: monday)
            }
        }.resume()
    }

    private func parseResponse(_ data: Data, monday: Date) {
        // Log raw response for debugging
        let rawPreview = String(data: data, encoding: .utf8)?.prefix(500) ?? "nil"
        print("Timing: raw response: \(rawPreview)")

        // Response is a JSON array of objects with "duration" (seconds) and "timespan" fields
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Try unwrapping from a "data" key
            if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("Timing: response is object with keys: \(wrapper.keys.sorted())")
                if let rows = wrapper["data"] as? [[String: Any]] {
                    print("Timing: found \(rows.count) rows under 'data' key")
                    processRows(rows, monday: monday)
                    return
                }
            }
            print("Timing: failed to parse response as JSON array or object")
            lastError = "Failed to parse response"
            return
        }
        print("Timing: parsed \(json.count) rows as top-level array")
        processRows(json, monday: monday)
    }

    private func processRows(_ rows: [[String: Any]], monday: Date) {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        // Build a map of date string → duration in seconds
        var durationByDate: [String: Double] = [:]
        if let firstRow = rows.first {
            print("Timing: first row keys: \(firstRow.keys.sorted())")
        }
        for row in rows {
            let duration = (row["duration"] as? Double) ?? (row["duration"] as? Int).map(Double.init) ?? 0

            // Extract the date from the timespan field
            if let timespan = row["timespan"] as? [String: Any],
               let start = timespan["start_date"] as? String {
                let dateStr = String(start.prefix(10))
                durationByDate[dateStr, default: 0] += duration
            } else if let startDate = row["start_date"] as? String {
                let dateStr = String(startDate.prefix(10))
                durationByDate[dateStr, default: 0] += duration
            } else {
                print("Timing: row has no timespan or start_date: \(row.keys.sorted())")
            }
        }
        print("Timing: durationByDate = \(durationByDate.sorted(by: { $0.key < $1.key }).map { "\($0.key): \(Int($0.value))s" })")

        // Build daily hours array for Mon-Sun
        var daily: [DailyTime] = []
        var total: Double = 0

        for i in 0..<7 {
            let date = calendar.date(byAdding: .day, value: i, to: monday)!
            let dateStr = df.string(from: date)
            let seconds = durationByDate[dateStr] ?? 0
            let hours = seconds / 3600.0
            total += hours
            daily.append(DailyTime(
                id: dayLabels[i],
                dayLabel: dayLabels[i],
                date: date,
                hours: hours
            ))
        }

        dailyHours = daily
        totalWeekHours = total
        print("Timing: processed \(rows.count) rows → \(daily.filter { $0.hours > 0 }.count) days with data, total=\(String(format: "%.1f", total))h")
        for d in daily where d.hours > 0 {
            print("Timing:   \(d.dayLabel): \(String(format: "%.1f", d.hours))h")
        }
    }
}
