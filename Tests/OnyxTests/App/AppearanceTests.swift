import XCTest
import AppKit
@testable import OnyxLib

/// Onyx is a jet-black overlay: every colour in it assumes a dark
/// backdrop. This is pinned because the failure is invisible to anyone
/// working in Dark Mode — the system appearance happens to match, so a
/// developer sees nothing while Light Mode users get white text fields
/// beside dark chips.
final class AppAppearanceTests: XCTestCase {

    func testTheWholeApplicationIsForcedDark() {
        let previous = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previous }

        NSApplication.shared.appearance = NSAppearance(named: .aqua)   // pretend Light Mode
        AppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))

        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua,
                       "the application appearance must be dark before any view exists")
    }

    /// Per-window styling stays as a backstop for windows created later,
    /// but it is no longer the only thing making the app dark — menus,
    /// popovers and field editors aren't windows we style.
    func testWindowsAreStyledDarkToo() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        AppDelegate.styleWindow(window)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }
}
