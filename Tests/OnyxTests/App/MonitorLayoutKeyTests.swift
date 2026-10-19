import XCTest
@testable import OnyxLib

/// A monitor key must never change something the current layout doesn't
/// show: the change is invisible when made and a mystery later.
final class MonitorLayoutKeyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    func testDInSimpleModeTogglesThePanel() {
        let app = AppState()
        app.monitorLayout = .simple
        app.appearance.simpleShowSidePanel = false
        app.handleSidePanelKey()
        XCTAssertTrue(app.appearance.simpleShowSidePanel)
        app.handleSidePanelKey()
        XCTAssertFalse(app.appearance.simpleShowSidePanel)
    }

    func testDInTheDetailedLayoutMeansSimpleModeWithThePanel() {
        let app = AppState()
        app.monitorLayout = .detailed
        // Already "on": D must not switch it off where it can't be seen.
        app.appearance.simpleShowSidePanel = true
        app.handleSidePanelKey()
        XCTAssertEqual(app.monitorLayout, .simple)
        XCTAssertTrue(app.appearance.simpleShowSidePanel)

        app.monitorLayout = .detailed
        app.appearance.simpleShowSidePanel = false
        app.handleSidePanelKey()
        XCTAssertEqual(app.monitorLayout, .simple)
        XCTAssertTrue(app.appearance.simpleShowSidePanel)
    }

    func testRDoesNothingInSimpleMode() {
        let app = AppState()
        app.monitorLayout = .simple
        let before = app.appearance.remindersDueSoonOnly
        XCTAssertFalse(app.handleRemindersDueSoonKey())
        XCTAssertEqual(app.appearance.remindersDueSoonOnly, before)

        app.monitorLayout = .detailed
        XCTAssertTrue(app.handleRemindersDueSoonKey())
        XCTAssertNotEqual(app.appearance.remindersDueSoonOnly, before)
    }
}

extension MonitorLayoutKeyTests {

    func testASwitchesTheAgendaPane() {
        let app = AppState()
        app.monitorLayout = .detailed
        app.appearance.agendaPane = .reminders
        app.handleAgendaKey()
        XCTAssertEqual(app.appearance.agendaPane, .calendar)
        app.handleAgendaKey()
        XCTAssertEqual(app.appearance.agendaPane, .reminders)
    }

    func testAInSimpleModeOpensTheSidePanelSoTheSwitchIsSeen() {
        let app = AppState()
        app.monitorLayout = .simple
        app.appearance.simpleShowSidePanel = false
        app.handleAgendaKey()
        XCTAssertTrue(app.appearance.simpleShowSidePanel)
        XCTAssertEqual(app.appearance.agendaPane, .calendar)
    }
}
