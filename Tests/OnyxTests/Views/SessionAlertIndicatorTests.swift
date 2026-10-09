import XCTest
@testable import OnyxLib

/// The bottom bar shows a bell only while something is unread. An empty
/// bell there said "you had messages once, and read them" — not worth the
/// space in the tightest strip on the screen.
final class SessionAlertIndicatorTests: XCTestCase {
    func testTheBarHidesTheBellOnceEverythingIsRead() {
        XCTAssertFalse(SessionAlertIndicator.isVisible(hasHistory: true, unseen: 0,
                                                       showsWhenAllRead: false, popoverOpen: false))
        XCTAssertTrue(SessionAlertIndicator.isVisible(hasHistory: true, unseen: 2,
                                                      showsWhenAllRead: false, popoverOpen: false))
    }

    /// Opening the popover marks everything read. If that hid the bell,
    /// the popover anchored to it would close the moment it opened.
    func testTheBellStaysWhileItsPopoverIsOpen() {
        XCTAssertTrue(SessionAlertIndicator.isVisible(hasHistory: true, unseen: 0,
                                                      showsWhenAllRead: false, popoverOpen: true))
    }

    func testTheMonitorStillShowsTheEmptyBell() {
        XCTAssertTrue(SessionAlertIndicator.isVisible(hasHistory: true, unseen: 0,
                                                      showsWhenAllRead: true, popoverOpen: false))
        XCTAssertFalse(SessionAlertIndicator.isVisible(hasHistory: false, unseen: 0,
                                                       showsWhenAllRead: true, popoverOpen: false),
                       "no history, nothing to offer")
    }
}
