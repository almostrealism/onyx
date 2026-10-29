import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Today's calendar in the agenda pane: all-day first, then by time; what
/// is over, on, and still to come.
final class TodayEventTests: XCTestCase {

    private let nine = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ hours: Double) -> Date { nine.addingTimeInterval(hours * 3600) }

    private func event(_ title: String, _ from: Double, _ to: Double, allDay: Bool = false) -> TodayEvent {
        TodayEvent(id: title, title: title, start: at(from), end: at(to), isAllDay: allDay, calendar: "Work")
    }

    func testAllDayFirstThenByStart() {
        let list = TodayEvent.ordered([event("lunch", 3, 4), event("standup", 0, 0.25),
                                       event("holiday", -9, 15, allDay: true), event("review", 3, 3.5)])
        XCTAssertEqual(list.map(\.title), ["holiday", "standup", "review", "lunch"])
    }

    func testTiming() {
        let e = event("standup", 0, 0.5)
        XCTAssertEqual(e.timing(at: at(-1)), .upcoming)
        XCTAssertEqual(e.timing(at: at(0.25)), .now)
        XCTAssertEqual(e.timing(at: at(0.5)), .past, "ends exactly now: over")
        XCTAssertEqual(event("holiday", -9, 15, allDay: true).timing(at: at(20)), .now)
    }

    func testRemainingDropsWhatIsOver() {
        let day = [event("standup", 0, 0.5), event("lunch", 3, 4), event("1:1", 1, 2)]
        XCTAssertEqual(TodayEvent.remaining(day, at: at(1.5)).map(\.title), ["1:1", "lunch"])
    }

    func testTheAgendaPaneDefaultsToRemindersForOldConfigs() throws {
        let config = try JSONDecoder().decode(AppearanceConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.agendaPane, .reminders)
    }

    // MARK: - Choosing calendars

    func testEveryCalendarIsShownForOldConfigs() throws {
        let config = try JSONDecoder().decode(AppearanceConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.hiddenCalendars, [])
    }

    func testHiddenCalendarsSurviveASave() throws {
        var config = AppearanceConfig()
        config.hiddenCalendars = [CalendarChoice.key(source: "iCloud", title: "Birthdays")]
        let back = try JSONDecoder().decode(AppearanceConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.hiddenCalendars, config.hiddenCalendars)
    }

    /// The same name in two accounts is two calendars.
    func testAChoiceIsItsAccountAndName() {
        let work = CalendarChoice(title: "Calendar", source: "Google")
        let home = CalendarChoice(title: "Calendar", source: "iCloud")
        XCTAssertNotEqual(work.id, home.id)
    }

    func testChoicesAreGroupedByAccountThenName() {
        let groups = CalendarChoice.grouped([
            CalendarChoice(title: "Work", source: "iCloud"),
            CalendarChoice(title: "team", source: "Google"),
            CalendarChoice(title: "Home", source: "iCloud"),
        ])
        XCTAssertEqual(groups.map(\.source), ["Google", "iCloud"])
        XCTAssertEqual(groups[1].calendars.map(\.title), ["Home", "Work"])
    }
}
