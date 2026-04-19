import XCTest
@testable import OnyxLib

/// Tests for the pure helpers that back the Timing panel stats and heatmap.
/// These cover the logic that was bug-prone historically (date math,
/// week boundaries, excluding today / in-progress week).
final class TimingManagerStatsTests: XCTestCase {

    /// Monday 2026-03-30 — a fixed, clearly-Monday anchor so tests don't
    /// depend on when they run.
    private var fixedMonday: Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 30
        return Calendar.current.date(from: comps)!
    }

    private let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func date(_ dayOffset: Int, from anchor: Date) -> String {
        let d = Calendar.current.date(byAdding: .day, value: dayOffset, to: anchor)!
        return df.string(from: d)
    }

    // MARK: - buildHeatmap

    private let W = TimingManager.heatmapWeeks

    func test_heatmap_hasCorrectShape() {
        let grid = TimingManager.buildHeatmap(hoursByDate: [:], anchorMonday: fixedMonday)
        XCTAssertEqual(grid.count, W)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
    }

    func test_heatmap_emptyInputIsAllZeros() {
        let grid = TimingManager.buildHeatmap(hoursByDate: [:], anchorMonday: fixedMonday)
        for col in grid {
            XCTAssertEqual(col, [0, 0, 0, 0, 0, 0, 0])
        }
    }

    /// Most recent week (last column) starts on anchorMonday; its row 0 is
    /// anchorMonday itself.
    func test_heatmap_currentWeekIsRightmostColumn() {
        let hours = [df.string(from: fixedMonday): 3.5]
        let grid = TimingManager.buildHeatmap(hoursByDate: hours, anchorMonday: fixedMonday)
        XCTAssertEqual(grid[W - 1][0], 3.5, "Current Monday should be grid[last][0]")
        XCTAssertEqual(grid[W - 2][0], 0, "Previous Monday should still be 0")
    }

    /// Oldest week (column 0) is (heatmapWeeks-1) weeks before anchorMonday.
    func test_heatmap_oldestColumnIsNWeeksBack() {
        let oldest = Calendar.current.date(byAdding: .day, value: -(W - 1) * 7, to: fixedMonday)!
        let hours = [df.string(from: oldest): 2.0]
        let grid = TimingManager.buildHeatmap(hoursByDate: hours, anchorMonday: fixedMonday)
        XCTAssertEqual(grid[0][0], 2.0)
    }

    /// Day rows map Mon..Sun as 0..6.
    func test_heatmap_dayRowsMonThroughSun() {
        var hours: [String: Double] = [:]
        for day in 0..<7 {
            hours[date(day, from: fixedMonday)] = Double(day + 1)
        }
        let grid = TimingManager.buildHeatmap(hoursByDate: hours, anchorMonday: fixedMonday)
        for day in 0..<7 {
            XCTAssertEqual(grid[W - 1][day], Double(day + 1),
                           "Day row \(day) should be \(day + 1) hours")
        }
    }

    // MARK: - avgHoursPerWeek: exclude current week

    func test_avgHoursPerWeek_excludesCurrentWeek() {
        // Put 10 hours on anchorMonday (current week) — must NOT count.
        // Put 8 hours on each of the last 4 Mondays — should average to 8.
        var hours: [String: Double] = [df.string(from: fixedMonday): 10]
        for w in 1...4 {
            let prevMonday = Calendar.current.date(byAdding: .day, value: -w * 7, to: fixedMonday)!
            hours[df.string(from: prevMonday)] = 8
        }
        let avg = TimingManager.avgHoursPerWeek(hoursByDate: hours, currentMonday: fixedMonday, weeks: 4)
        XCTAssertEqual(avg, 8, accuracy: 0.001)
    }

    /// Weeks with no data still count in the denominator — the stat is
    /// "average per week", not "average per week with data".
    func test_avgHoursPerWeek_emptyWeeksPullAverageDown() {
        // 40 hours total across 4 weeks = 10/week average, not 40.
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: fixedMonday)!
        let hours = [df.string(from: oneWeekAgo): 40.0]
        let avg = TimingManager.avgHoursPerWeek(hoursByDate: hours, currentMonday: fixedMonday, weeks: 4)
        XCTAssertEqual(avg, 10, accuracy: 0.001)
    }

    func test_avgHoursPerWeek_zeroInputIsZero() {
        let avg = TimingManager.avgHoursPerWeek(hoursByDate: [:], currentMonday: fixedMonday, weeks: 4)
        XCTAssertEqual(avg, 0)
    }

    /// Sums across all 7 days of each of the 4 preceding weeks.
    func test_avgHoursPerWeek_sumsAllDaysInWeek() {
        var hours: [String: Double] = [:]
        let prevWeekMonday = Calendar.current.date(byAdding: .day, value: -7, to: fixedMonday)!
        for day in 0..<7 {
            hours[date(day, from: prevWeekMonday)] = 2.0  // 14 hrs in that week
        }
        let avg = TimingManager.avgHoursPerWeek(hoursByDate: hours, currentMonday: fixedMonday, weeks: 4)
        // 14 hours one week / 4 weeks = 3.5
        XCTAssertEqual(avg, 3.5, accuracy: 0.001)
    }

    // MARK: - avgHoursPerDay: exclude today

    func test_avgHoursPerDay_excludesToday() {
        let today = fixedMonday  // treat Monday 2026-03-30 as "today"
        // 100 hours on today — must NOT count
        var hours = [df.string(from: today): 100.0]
        // 3 hours each on the last 5 days → expect 3*5/30 = 0.5
        for d in 1...5 {
            let prev = Calendar.current.date(byAdding: .day, value: -d, to: today)!
            hours[df.string(from: prev)] = 3.0
        }
        let avg = TimingManager.avgHoursPerDay(hoursByDate: hours, today: today, days: 30)
        XCTAssertEqual(avg, 15.0 / 30, accuracy: 0.001)
    }

    func test_avgHoursPerDay_denominatorIsFullRange() {
        // 30 hours total over the 30-day window → avg = 1/day regardless of
        // how many days actually had data.
        var hours: [String: Double] = [:]
        let today = fixedMonday
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        hours[df.string(from: yesterday)] = 30
        let avg = TimingManager.avgHoursPerDay(hoursByDate: hours, today: today, days: 30)
        XCTAssertEqual(avg, 1.0, accuracy: 0.001)
    }

    func test_avgHoursPerDay_zeroInputIsZero() {
        let avg = TimingManager.avgHoursPerDay(hoursByDate: [:], today: fixedMonday, days: 30)
        XCTAssertEqual(avg, 0)
    }

    /// Custom day counts work (e.g., 7-day trailing average).
    func test_avgHoursPerDay_customDayCount() {
        var hours: [String: Double] = [:]
        for d in 1...7 {
            let prev = Calendar.current.date(byAdding: .day, value: -d, to: fixedMonday)!
            hours[df.string(from: prev)] = 2.0
        }
        let avg = TimingManager.avgHoursPerDay(hoursByDate: hours, today: fixedMonday, days: 7)
        XCTAssertEqual(avg, 2.0, accuracy: 0.001)
    }
}
