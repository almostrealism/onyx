import XCTest
@testable import OnyxCore
@testable import OnyxLib

final class PanelSplitTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "PanelSplitTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testANewWindowGetsTheDefault() {
        XCTAssertEqual(PanelSplit.load(window: 0, from: defaults), PanelSplit.defaultFraction)
    }

    func testEachWindowKeepsItsOwnWidth() {
        PanelSplit.save(0.55, window: 0, to: defaults)
        PanelSplit.save(0.3, window: 1, to: defaults)
        XCTAssertEqual(PanelSplit.load(window: 0, from: defaults), 0.55, accuracy: 0.0001)
        XCTAssertEqual(PanelSplit.load(window: 1, from: defaults), 0.3, accuracy: 0.0001)
        XCTAssertEqual(PanelSplit.load(window: 2, from: defaults), PanelSplit.defaultFraction)
    }

    /// A stored value outside the limits (an older build's, a hand edit)
    /// must not open a panel that hides the terminal or vanishes.
    func testAStoredWidthIsClampedOnTheWayOut() {
        defaults.set(0.99, forKey: PanelSplit.key(window: 0))
        defaults.set(0.01, forKey: PanelSplit.key(window: 1))
        XCTAssertEqual(PanelSplit.load(window: 0, from: defaults), PanelSplit.maxFraction)
        XCTAssertEqual(PanelSplit.load(window: 1, from: defaults), PanelSplit.minFraction)
    }

    func testDraggingTheDivider() {
        XCTAssertEqual(PanelSplit.fraction(dividerAt: 600, width: 1000), 0.4, accuracy: 0.0001)
        XCTAssertEqual(PanelSplit.fraction(dividerAt: 0, width: 1000), PanelSplit.maxFraction)
        XCTAssertEqual(PanelSplit.fraction(dividerAt: 1000, width: 1000), PanelSplit.minFraction)
        XCTAssertEqual(PanelSplit.fraction(dividerAt: 10, width: 0), PanelSplit.defaultFraction)
    }

    func testCmdBackslashStepsWiderThenWraps() {
        XCTAssertEqual(PanelSplit.nextPreset(after: 0.4), 0.5)
        XCTAssertEqual(PanelSplit.nextPreset(after: 0.45), 0.5)
        XCTAssertEqual(PanelSplit.nextPreset(after: 0.7), 0.3)
        XCTAssertEqual(PanelSplit.nextPreset(after: 0.8), 0.3)
    }
}
