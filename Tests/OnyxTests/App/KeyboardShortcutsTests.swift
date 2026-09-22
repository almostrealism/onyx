import XCTest
@testable import OnyxLib

/// The bare backtick — the key that raises and lowers the monitor.
///
/// With the monitor up, ⌘J opens the session list over it, and the list
/// used to block the backtick whether or not anyone was typing into it:
/// the key that raised the monitor could no longer lower it.
final class BacktickRoutingTests: XCTestCase {

    private func action(sessionList: Bool = false, otherOverlay: Bool = false,
                        rightPanel: Bool = false, typing: Bool = false)
        -> ShortcutManager.BacktickAction {
        ShortcutManager.backtickAction(sessionListOpen: sessionList,
                                         otherTextOverlay: otherOverlay,
                                         rightPanelOpen: rightPanel,
                                         typingInTextField: typing)
    }

    func testAloneItTogglesTheMonitor() {
        XCTAssertEqual(action(), .toggleMonitor)
    }

    /// The ask: monitor up, ⌘J list up, nobody typing → the list
    /// collapses and the monitor goes down, in one keystroke.
    func testWithTheSessionListUpItCollapsesTheListToo() {
        XCTAssertEqual(action(sessionList: true), .collapseSessionListAndToggleMonitor)
    }

    /// …unless the keyboard is in one of the list's fields, where a
    /// backtick is a character.
    func testTypingInTheSessionListKeepsTheKey() {
        XCTAssertEqual(action(sessionList: true, typing: true), .passThrough)
    }

    /// Settings, the palette, the note editor: unchanged, they own the key.
    func testOtherTextOverlaysStillOwnTheKey() {
        XCTAssertEqual(action(otherOverlay: true), .passThrough)
        XCTAssertEqual(action(sessionList: true, otherOverlay: true), .passThrough)
    }

    func testARightPanelStillOwnsTheKey() {
        XCTAssertEqual(action(rightPanel: true), .passThrough)
    }
}
