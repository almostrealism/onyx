//
// AgentTimeStore.swift
//
// Responsibility: Agent hours from the flowtree controller — wall-clock time
//                 its jobs ran, per day, across every workstream — for the
//                 monitor's Timing section.
// Scope: Shared singleton; every window's TimingManager reads it.
// Threading: The fetch runs as a Task; results are published on main.
//
// Fetched for the days the Timing numbers need: the current week, the four
// completed weeks before it (the 4-week average), and the 30 days before
// today (the 30-day average). Days are counted in this Mac's time zone, so
// they line up with Timing's.
//
// Polls only while a controller is configured. A controller that predates
// `/api/stats/daily` answers with something else; that clears the days
// and says so, rather than showing zeros as if no agent ran.
//

import Foundation
import Combine

public final class AgentTimeStore: ObservableObject {

    public static let shared = AgentTimeStore()

    /// One entry per day, oldest first. Empty until the first fetch, and
    /// when the controller can't answer.
    @Published public private(set) var days: [AgentDay] = []
    /// Why there are no days, when there should be.
    @Published public private(set) var lastError: String?

    private var timer: Timer?
    private var configCancellable: AnyCancellable?
    private let refreshInterval: TimeInterval = 300

    private init() {}

    public var isConfigured: Bool { FlowtreeConfigStore.shared.isConfigured }

    /// Start polling. Idempotent. Also refetches when the controller
    /// settings change, so a newly entered URL shows hours right away.
    public func startPolling() {
        if configCancellable == nil {
            configCancellable = FlowtreeConfigStore.shared.objectWillChange
                .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }
        }
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Fetch now.
    public func refresh() {
        guard isConfigured else {
            days = []
            lastError = nil
            return
        }
        let range = Self.range(today: Date(), calendar: .current)
        let client = FlowtreeClient(config: FlowtreeConfigStore.shared.config)
        let zone = TimeZone.current.identifier
        Task { @MainActor [weak self] in
            do {
                let stats = try await client.dailyStats(from: range.from, to: range.to, timeZone: zone)
                self?.days = stats.days
                self?.lastError = nil
            } catch {
                self?.days = []
                self?.lastError = Self.message(for: error)
            }
        }
    }

    /// What to say when the fetch failed.
    static func message(for error: Error) -> String {
        if let error = error as? FlowtreeError, case .decode = error {
            return "The flowtree controller doesn't report agent hours yet — it needs /api/stats/daily."
        }
        return "Agent hours: \(error.localizedDescription)"
    }

    /// The days to ask for, as `yyyy-MM-dd`: from four weeks before this
    /// week's Monday (or 30 days before today, if earlier) through today.
    static func range(today: Date, calendar: Calendar) -> (from: String, to: String) {
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let fourWeeksBack = calendar.date(byAdding: .day, value: -28, to: monday)!
        let thirtyDaysBack = calendar.date(byAdding: .day, value: -30, to: today)!
        let from = min(fourWeeksBack, thirtyDaysBack)
        let df = DateFormatter()
        df.calendar = calendar
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        return (df.string(from: from), df.string(from: today))
    }
}
