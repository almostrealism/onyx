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
        guard isConfigured else { return }
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
        }
    }

    // MARK: - API

    private func fetch() {
        guard !apiToken.isEmpty else { return }
        isLoading = true

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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if let error = error {
                    self.lastError = error.localizedDescription
                    return
                }

                guard let data = data else {
                    self.lastError = "No data received"
                    return
                }

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    self.lastError = "HTTP \(httpResponse.statusCode): \(body.prefix(100))"
                    return
                }

                self.lastError = nil
                self.parseResponse(data, monday: monday)
            }
        }.resume()
    }

    private func parseResponse(_ data: Data, monday: Date) {
        // Response is a JSON array of objects with "duration" (seconds) and "timespan" fields
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Try unwrapping from a "data" key
            if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = wrapper["data"] as? [[String: Any]] {
                processRows(rows, monday: monday)
                return
            }
            lastError = "Failed to parse response"
            return
        }
        processRows(json, monday: monday)
    }

    private func processRows(_ rows: [[String: Any]], monday: Date) {
        let calendar = Calendar.current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

        // Build a map of date string → duration in seconds
        var durationByDate: [String: Double] = [:]
        for row in rows {
            let duration = (row["duration"] as? Double) ?? (row["duration"] as? Int).map(Double.init) ?? 0

            // Extract the date from the timespan field
            if let timespan = row["timespan"] as? [String: Any],
               let start = timespan["start_date"] as? String {
                // start_date might be "2024-01-15" or "2024-01-15T00:00:00..."
                let dateStr = String(start.prefix(10))
                durationByDate[dateStr, default: 0] += duration
            } else if let startDate = row["start_date"] as? String {
                let dateStr = String(startDate.prefix(10))
                durationByDate[dateStr, default: 0] += duration
            }
        }

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
    }
}
