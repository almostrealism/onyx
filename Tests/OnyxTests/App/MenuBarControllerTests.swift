import XCTest
@testable import OnyxLib

/// What the menu bar item shows, and in what order.
///
/// The rules matter more than they look: this menu exists to answer "which
/// session is bouncing" at a glance, so a session with an unseen alert
/// being anywhere but the top — or missing entirely because it has no note
/// — makes the feature useless in exactly the case it was built for.
final class MenuBarRowTests: XCTestCase {

    private func row(_ key: String, note: String? = nil,
                     noteAge: TimeInterval = 0,
                     alerts: [SessionAlert] = []) -> MenuBarController.Row {
        MenuBarController.Row(
            key: key,
            label: key,
            note: note.map { SessionNote(sessionID: key, text: $0,
                                         updated: Date().addingTimeInterval(-noteAge)) },
            alerts: alerts)
    }

    private func alert(_ title: String, seen: Bool = false,
                       age: TimeInterval = 0) -> SessionAlert {
        SessionAlert(at: Date().addingTimeInterval(-age), title: title, seen: seen)
    }

    func testASessionWithNeitherNoteNorAlertIsNotListed() {
        let rows = MenuBarController.rows(from: [row("quiet")])
        XCTAssertTrue(rows.isEmpty)
    }

    /// The case the whole feature is for: an alerting session with no note
    /// must still appear, or the bounce has no explanation anywhere.
    func testASessionWithAlertsButNoNoteIsListed() {
        let rows = MenuBarController.rows(from: [row("loud", alerts: [alert("blocked")])])
        XCTAssertEqual(rows.map(\.key), ["loud"])
    }

    func testUnseenAlertsSortAboveEverythingElse() {
        let rows = MenuBarController.rows(from: [
            row("fresh-note", note: "just written", noteAge: 0),
            row("old-note", note: "ages ago", noteAge: 9_000),
            row("alerting", note: "older still", noteAge: 20_000,
                alerts: [alert("needs you", age: 600)]),
        ])
        XCTAssertEqual(rows.first?.key, "alerting",
                       "an unseen alert outranks the most recently written note")
    }

    /// "Seen" is not "unimportant" — the session stays listed — but it no
    /// longer jumps the queue.
    func testASeenAlertDoesNotJumpTheQueue() {
        let rows = MenuBarController.rows(from: [
            row("read", note: "old", noteAge: 9_000, alerts: [alert("done", seen: true, age: 60)]),
            row("recent", note: "new", noteAge: 5),
        ])
        XCTAssertEqual(rows.map(\.key), ["recent", "read"])
    }

    func testNotedSessionsWithoutAlertsSortByRecency() {
        let rows = MenuBarController.rows(from: [
            row("b", note: "second", noteAge: 100),
            row("a", note: "first", noteAge: 10),
            row("c", note: "third", noteAge: 1_000),
        ])
        XCTAssertEqual(rows.map(\.key), ["a", "b", "c"])
    }

    func testUnseenCountIgnoresSeenAlerts() {
        let r = row("k", alerts: [alert("one"), alert("two", seen: true), alert("three")])
        XCTAssertEqual(r.unseen, 2)
    }

    // MARK: - Text

    func testAlertLinesLeadWithTheTime() {
        let line = MenuBarController.alertLine(alert("Migration needs a decision"))
        XCTAssertTrue(line.contains("Migration needs a decision"))
        XCTAssertEqual(line.prefix(2).count, 2)
        XCTAssertTrue(line.contains(":"), "the time is first, so a column reads as a timeline")
    }

    /// A menu item is one line. An agent's multi-line title would
    /// otherwise stretch the menu to the width of the screen.
    func testLongAndMultilineTextIsFlattenedAndClipped() {
        XCTAssertEqual(MenuBarController.clip("one\ntwo", 40), "one two")
        let long = String(repeating: "x", count: 100)
        let clipped = MenuBarController.clip(long, 20)
        XCTAssertEqual(clipped.count, 20)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(MenuBarController.clip("  fine  ", 40), "fine")
    }
}
