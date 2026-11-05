import XCTest
@testable import OnyxCore

/// The compact window (⇧⌘D) and the full one each keep their own frame.
final class WindowModeFramesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        suite = "onyx-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testEachShapeKeepsItsOwnFramePerWindow() {
        let full = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let compact = CGRect(x: 1400, y: 80, width: 340, height: 900)
        WindowModeFrames.save(full, as: .full, window: 0, to: defaults)
        WindowModeFrames.save(compact, as: .compact, window: 0, to: defaults)
        XCTAssertEqual(WindowModeFrames.load(.full, window: 0, from: defaults), full)
        XCTAssertEqual(WindowModeFrames.load(.compact, window: 0, from: defaults), compact)
        XCTAssertNil(WindowModeFrames.load(.full, window: 1, from: defaults), "window 1 has its own")
    }

    func testWhetherAWindowWasCompactIsRemembered() {
        XCTAssertFalse(WindowModeFrames.isCompact(window: 2, in: defaults))
        WindowModeFrames.setCompact(true, window: 2, in: defaults)
        XCTAssertTrue(WindowModeFrames.isCompact(window: 2, in: defaults))
        XCTAssertFalse(WindowModeFrames.isCompact(window: 0, in: defaults))
    }

    /// The first compact window keeps the full one's right edge and height,
    /// so it doesn't jump across the screen.
    func testTheFirstCompactFrameKeepsTheRightEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let full = CGRect(x: 200, y: 100, width: 1200, height: 800)
        let compact = WindowModeFrames.firstCompactFrame(from: full, width: 344, on: screen)
        XCTAssertEqual(compact, CGRect(x: 1056, y: 100, width: 344, height: 800))
        XCTAssertEqual(WindowModeFrames.firstCompactFrame(from: full, width: 100, on: screen).width,
                       WindowModeFrames.compactMinSize.width)
    }

    /// A frame from a display that's gone is brought onto this one.
    func testAFrameOffTheScreenIsBroughtOnIt() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fitted = WindowModeFrames.fitted(CGRect(x: 2500, y: -300, width: 400, height: 1200), on: screen)
        XCTAssertEqual(fitted, CGRect(x: 1040, y: 0, width: 400, height: 900))
        let inside = CGRect(x: 10, y: 10, width: 300, height: 300)
        XCTAssertEqual(WindowModeFrames.fitted(inside, on: screen), inside)
    }

    func testANonsenseFrameIsNotLoaded() {
        defaults.set([1.0, 2.0, 0.0, 5.0], forKey: WindowModeFrames.frameKey(.full, window: 0))
        XCTAssertNil(WindowModeFrames.load(.full, window: 0, from: defaults))
    }
}
