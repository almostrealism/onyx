import XCTest
@testable import OnyxLib

/// Agent hours from the flowtree controller: the request, the response, and
/// how a run of days becomes the agents column beside the Timing numbers.
final class AgentHoursTests: XCTestCase {

    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func date(_ s: String) -> Date { df.date(from: s)! }

    // MARK: - Request and response

    func testThePathCarriesTheRangeAndZone() {
        let path = FlowtreeClient.dailyStatsPath(from: "2026-09-14", to: "2026-10-20",
                                                 timeZone: "America/Los_Angeles")
        XCTAssertEqual(path, "/api/stats/daily?from=2026-09-14&to=2026-10-20&tz=America/Los_Angeles")
        let req = FlowtreeClient.makeRequest(config: FlowtreeConfig(baseURL: "https://ft.example.com"),
                                             path: path, method: "GET")
        XCTAssertEqual(req?.url?.query, "from=2026-09-14&to=2026-10-20&tz=America/Los_Angeles")
    }

    /// A "+" left bare in a query is read as a space by the server.
    func testAPlusInAZoneIsEncoded() {
        let path = FlowtreeClient.dailyStatsPath(from: "2026-10-01", to: "2026-10-02", timeZone: "Etc/GMT+5")
        XCTAssertTrue(path.hasSuffix("tz=Etc/GMT%2B5"), path)
    }

    func testTheResponseDecodes() throws {
        let json = #"{"tz":"America/Los_Angeles","days":[{"date":"2026-10-01","wallClockMs":14400000,"runningMs":1800000,"jobCount":2,"costUsd":1.5}]}"#
        let stats = try JSONDecoder().decode(FlowtreeDailyStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.days.count, 1)
        XCTAssertEqual(stats.days[0].hours, 4.5, accuracy: 0.0001, "finished and running time together")
    }

    /// An older controller sends the weekly stats for this path: that must
    /// fail to decode, not decode as no days.
    func testAnOlderControllersReplyDoesNotDecode() {
        let weekly = #"{"thisWeek":{"weekStart":"2026-10-19","stats":{}},"lastWeek":{"weekStart":"2026-10-12","stats":{}},"lastJobAt":null}"#
        XCTAssertThrowsError(try JSONDecoder().decode(FlowtreeDailyStats.self, from: Data(weekly.utf8)))
        XCTAssertTrue(AgentTimeStore.message(for: FlowtreeError.decode("x")).contains("/api/stats/daily"))
    }

    /// Enough days for both averages: four weeks before this Monday, or 30
    /// days before today when that reaches further.
    func testTheRangeCoversBothAverages() {
        let cal = Calendar.current
        // Monday: four weeks back from Monday is 28 days, 30 days back is further.
        XCTAssertEqual(AgentTimeStore.range(today: date("2026-10-19"), calendar: cal).from, "2026-09-19")
        // Sunday: Monday-28 is 34 days back, further than 30.
        let sunday = AgentTimeStore.range(today: date("2026-10-25"), calendar: cal)
        XCTAssertEqual(sunday.from, "2026-09-21")
        XCTAssertEqual(sunday.to, "2026-10-25")
    }

    // MARK: - The agents column

    func testNoDaysMeansNoColumn() {
        XCTAssertNil(TimingManager.agentGroup(days: [], monday: date("2026-10-19"), today: date("2026-10-21")))
    }

    /// The week, its per-day figure, and the two averages, counted the same
    /// way as a project's.
    func testTheColumnsNumbers() throws {
        var days: [AgentDay] = []
        // This week: Mon 30h, Tue 10h (Wed is today, nothing yet).
        days.append(AgentDay(date: "2026-10-19", wallClockMs: 30 * 3_600_000))
        days.append(AgentDay(date: "2026-10-20", wallClockMs: 6 * 3_600_000, runningMs: 4 * 3_600_000))
        // Previous four weeks: 7h every day.
        for offset in 1...28 {
            let d = Calendar.current.date(byAdding: .day, value: -offset, to: date("2026-10-19"))!
            days.append(AgentDay(date: df.string(from: d), wallClockMs: 7 * 3_600_000))
        }
        let group = try XCTUnwrap(TimingManager.agentGroup(days: days, monday: date("2026-10-19"),
                                                           today: date("2026-10-21")))
        XCTAssertEqual(group.dailyHours.count, 7)
        XCTAssertEqual(group.totalWeekHours, 40, accuracy: 0.001)
        XCTAssertEqual(group.perDayThisWeek, 20, accuracy: 0.001, "over the days that had any")
        XCTAssertEqual(group.avgHoursPerWeekLast4, 49, accuracy: 0.001)
        // 30 days before Oct 21: Oct 20 (10h), Oct 19 (30h), 28 days of 7h → 236h.
        XCTAssertEqual(group.avgHoursPerDayLast30, 236.0 / 30, accuracy: 0.001)
        XCTAssertTrue(group.projectTotals.isEmpty, "no project split, so no ratio bar")
    }

    /// A week with no agent time is still a column: zero is an answer.
    func testAQuietWeekIsStillShown() throws {
        let group = try XCTUnwrap(TimingManager.agentGroup(
            days: [AgentDay(date: "2026-10-01", wallClockMs: 3_600_000)],
            monday: date("2026-10-19"), today: date("2026-10-21")))
        XCTAssertEqual(group.totalWeekHours, 0)
    }

    /// The agents never join the bar chart: they aren't one of the groups.
    func testAgentsAreNotABarChartGroup() {
        let result = TimingManager.compute(rows: [], projects: [], filterIDs: [],
                                           monday: date("2026-10-19"), today: date("2026-10-21"))
        XCTAssertFalse(result.groups.contains { $0.id == "agents" })
    }
}
