import XCTest
@testable import OnyxLib

/// Reordering the monitor's Reminders lists. The order of the array is the
/// order on screen; it used to be settable only by choosing the lists one
/// at a time in the order wanted.
final class ReminderListOrderTests: XCTestCase {
    private let lists = ["Work", "Onyx", "Home", "Errands"]

    func testDraggingOntoARowTakesItsPlace() {
        XCTAssertEqual(ReminderListOrder.move("Errands", to: "Work", in: lists),
                       ["Errands", "Work", "Onyx", "Home"], "dragged up to the top")
        XCTAssertEqual(ReminderListOrder.move("Work", to: "Home", in: lists),
                       ["Onyx", "Home", "Work", "Errands"], "dragged down past two")
        XCTAssertEqual(ReminderListOrder.move("Onyx", to: "Home", in: lists),
                       ["Work", "Home", "Onyx", "Errands"], "neighbors swap")
    }

    func testMovingOntoItselfOrAnUnknownListChangesNothing() {
        XCTAssertEqual(ReminderListOrder.move("Onyx", to: "Onyx", in: lists), lists)
        XCTAssertEqual(ReminderListOrder.move("Nope", to: "Onyx", in: lists), lists)
        XCTAssertEqual(ReminderListOrder.move("Onyx", to: "Nope", in: lists), lists)
    }

    func testNudgingIsClampedAtBothEnds() {
        XCTAssertEqual(ReminderListOrder.nudge("Onyx", by: -1, in: lists), ["Onyx", "Work", "Home", "Errands"])
        XCTAssertEqual(ReminderListOrder.nudge("Onyx", by: 1, in: lists), ["Work", "Home", "Onyx", "Errands"])
        XCTAssertEqual(ReminderListOrder.nudge("Work", by: -1, in: lists), lists)
        XCTAssertEqual(ReminderListOrder.nudge("Errands", by: 1, in: lists), lists)
    }

    func testAddingAppendsOnceAndRemovingTheLastReturnsToToday() {
        XCTAssertEqual(ReminderListOrder.add("Groceries", to: lists), lists + ["Groceries"])
        XCTAssertEqual(ReminderListOrder.add("Home", to: lists), lists, "already shown")
        XCTAssertEqual(ReminderListOrder.remove("Home", from: lists), ["Work", "Onyx", "Errands"])
        XCTAssertEqual(ReminderListOrder.remove("Work", from: ["Work"]), [],
                       "an empty selection is Today mode")
    }

    /// A list renamed or deleted in Reminders stays visible, marked, so it
    /// can be removed — instead of vanishing and coming back with the list.
    func testShownMarksListsThatNoLongerExist() {
        let rows = ReminderListOrder.shown(["Work", "Old"], available: ["Home", "Work"])
        XCTAssertEqual(rows, [.init(name: "Work", missing: false), .init(name: "Old", missing: true)])
    }

    func testHiddenIsWhatExistsAndIsntShownAlphabetically() {
        XCTAssertEqual(ReminderListOrder.hidden(["Work"], available: ["work 2", "Errands", "Work", "Home"]),
                       ["Errands", "Home", "work 2"])
    }
}
