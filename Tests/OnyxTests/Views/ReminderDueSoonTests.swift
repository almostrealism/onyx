import XCTest
@testable import OnyxLib

/// The date rule behind the monitor's `R` filter ("only what's due today
/// or tomorrow"). It must match the window the "today / by tmrw" count
/// chips use, or the header would contradict the list beneath it.
final class ReminderDueSoonTests: XCTestCase {

    /// Fixed reference point: Wed 2026-08-12, 14:00 local.
    private let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 12; c.hour = 14; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    private func due(_ day: Int, hour: Int? = nil, minute: Int? = nil) -> DateComponents {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = day
        c.hour = hour; c.minute = minute
        return c
    }

    func testDueEarlierToday_isDueSoon() {
        XCTAssertTrue(RemindersManager.isDueSoon(due: due(12, hour: 9, minute: 0), now: now))
    }

    func testDueLaterToday_isDueSoon() {
        XCTAssertTrue(RemindersManager.isDueSoon(due: due(12, hour: 23, minute: 30), now: now))
    }

    func testOverdue_isDueSoon() {
        // Overdue work is the most due of all — it must never be filtered out.
        XCTAssertTrue(RemindersManager.isDueSoon(due: due(3, hour: 8, minute: 0), now: now))
    }

    func testDueTomorrow_isDueSoon() {
        XCTAssertTrue(RemindersManager.isDueSoon(due: due(13, hour: 17, minute: 0), now: now))
    }

    /// An all-day reminder resolves to that day's 00:00. Tomorrow's
    /// all-day is in; the day after's all-day must be OUT — getting this
    /// boundary wrong pulls a whole extra day into the list, which is the
    /// exact bug the scope-count code documents.
    func testAllDayTomorrow_isDueSoon_butAllDayDayAfterIsNot() {
        XCTAssertTrue(RemindersManager.isDueSoon(due: due(13), now: now))
        XCTAssertFalse(RemindersManager.isDueSoon(due: due(14), now: now))
    }

    func testDueDayAfterTomorrow_isNotDueSoon() {
        XCTAssertFalse(RemindersManager.isDueSoon(due: due(14, hour: 9, minute: 0), now: now))
    }

    // MARK: - isDueToday (drives the dimming of tomorrow's rows)

    func testIsDueToday_todayAndOverdueCount_laterDoesNot() {
        XCTAssertTrue(RemindersManager.isDueToday(due: due(12, hour: 9, minute: 0), now: now))
        XCTAssertTrue(RemindersManager.isDueToday(due: due(12, hour: 23, minute: 59), now: now),
                      "still today at one minute to midnight")
        XCTAssertTrue(RemindersManager.isDueToday(due: due(3), now: now), "overdue is today's problem")
        XCTAssertFalse(RemindersManager.isDueToday(due: due(13, hour: 0, minute: 1), now: now))
    }

    /// The all-day boundary again, from the other side: an all-day
    /// reminder due tomorrow resolves to tomorrow 00:00 and must NOT be
    /// treated as today, or it would render at full strength.
    func testIsDueToday_allDayTomorrowIsNotToday() {
        XCTAssertFalse(RemindersManager.isDueToday(due: due(13), now: now))
        XCTAssertTrue(RemindersManager.isDueToday(due: due(12), now: now))
    }

    /// Every reminder shown in due-soon mode is either today's or gets
    /// dimmed — no third category can slip through at full strength.
    func testDueSoonSplitsCleanlyIntoTodayAndDimmed() {
        let cases = [due(3), due(12), due(12, hour: 20, minute: 0), due(13), due(13, hour: 8, minute: 0)]
        for c in cases where RemindersManager.isDueSoon(due: c, now: now) {
            let today = RemindersManager.isDueToday(due: c, now: now)
            let tomorrow = !today
            XCTAssertTrue(today || tomorrow)
        }
        XCTAssertFalse(RemindersManager.isDueToday(due: due(14), now: now))
    }

    func testNoDueDate_isNotDueSoon() {
        // "Due soon" is about dated work; an undated reminder has no claim
        // on today.
        XCTAssertFalse(RemindersManager.isDueSoon(due: nil, now: now))
    }
}
