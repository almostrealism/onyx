import XCTest
@testable import OnyxLib

/// Locks the overlay/input-gating contract of SessionConnectionState.
/// The overlay must show if and only if the state says so, and keyboard
/// input must be gated exactly when the process isn't live.
final class SessionConnectionStateTests: XCTestCase {

    func testConnected_doesNotGateInput_showsNoOverlay() {
        let s = SessionConnectionState.connected
        XCTAssertFalse(s.shouldGateInput)
        XCTAssertFalse(s.showReconnectingOverlay)
        XCTAssertFalse(s.showErrorOverlay)
        XCTAssertNil(s.errorMessage)
    }

    func testReattaching_gatesInput_showsReconnectingOnly() {
        let s = SessionConnectionState.reattaching(reason: "connection lost", since: Date())
        XCTAssertTrue(s.shouldGateInput)
        XCTAssertTrue(s.showReconnectingOverlay)
        XCTAssertFalse(s.showErrorOverlay)
        XCTAssertNil(s.errorMessage)
    }

    func testFailed_gatesInput_showsErrorOnly() {
        let s = SessionConnectionState.failed(error: "boom")
        XCTAssertTrue(s.shouldGateInput)
        XCTAssertFalse(s.showReconnectingOverlay)
        XCTAssertTrue(s.showErrorOverlay)
        XCTAssertEqual(s.errorMessage, "boom")
    }

    func testNeedsKeySetup_gatesInput_showsErrorOnly() {
        let s = SessionConnectionState.needsKeySetup(error: "install key")
        XCTAssertTrue(s.shouldGateInput)
        XCTAssertFalse(s.showReconnectingOverlay)
        XCTAssertTrue(s.showErrorOverlay)
        XCTAssertEqual(s.errorMessage, "install key")
    }

    /// The two overlays are mutually exclusive across all states.
    func testOverlays_mutuallyExclusive() {
        let states: [SessionConnectionState] = [
            .connected,
            .reattaching(reason: "x", since: Date()),
            .failed(error: "x"),
            .needsKeySetup(error: "x"),
        ]
        for s in states {
            XCTAssertFalse(s.showReconnectingOverlay && s.showErrorOverlay, "state: \(s)")
        }
    }

    func testHostConnectionState_isUsable() {
        XCTAssertTrue(HostConnectionState.connected.isUsable)
        XCTAssertTrue(HostConnectionState.degraded.isUsable)
        XCTAssertTrue(HostConnectionState.failing.isUsable)
        XCTAssertFalse(HostConnectionState.initializing.isUsable)
        XCTAssertFalse(HostConnectionState.connecting.isUsable)
        XCTAssertFalse(HostConnectionState.down.isUsable)
        XCTAssertFalse(HostConnectionState.offline.isUsable)
        XCTAssertFalse(HostConnectionState.sleeping.isUsable)
    }
}
