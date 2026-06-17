import XCTest
@testable import OnyxLib

final class TerminalActivityStoreTests: XCTestCase {

    private var store: TerminalActivityStore { TerminalActivityStore.shared }

    // Unique session ids per test keep the shared singleton's state from
    // leaking between cases (there's no public reset).
    private func sid(_ name: String = #function) -> String { "test-\(name)" }

    func test_unknownSession_isNil() {
        XCTAssertNil(store.lastOutput(for: "never-seen-\(UUID().uuidString)"))
    }

    func test_recordOutput_setsTimestamp() {
        let id = sid()
        let before = Date()
        store.recordOutput(sessionID: id)
        let stamp = store.lastOutput(for: id)
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual(stamp!.timeIntervalSince(before), 0)
    }

    func test_recordOutput_advancesTimestamp() {
        let id = sid()
        store.recordOutput(sessionID: id)
        let first = store.lastOutput(for: id)!
        Thread.sleep(forTimeInterval: 0.02)
        store.recordOutput(sessionID: id)
        let second = store.lastOutput(for: id)!
        XCTAssertGreaterThan(second, first)
    }

    func test_sessionsAreIndependent() {
        let a = sid() + "a", b = sid() + "b"
        store.recordOutput(sessionID: a)
        XCTAssertNotNil(store.lastOutput(for: a))
        XCTAssertNil(store.lastOutput(for: b))
    }

    // MARK: - Disconnect / reconnect suppression

    func test_disconnected_ignoresOutput() {
        let id = sid()
        store.recordOutput(sessionID: id)
        let idleStamp = store.lastOutput(for: id)!
        // Connection drops; reconnect chatter arrives — must be ignored.
        store.markDisconnected(sessionID: id)
        Thread.sleep(forTimeInterval: 0.02)
        store.recordOutput(sessionID: id)
        XCTAssertEqual(store.lastOutput(for: id), idleStamp,
                       "output while disconnected must not advance the idle clock")
    }

    func test_reconnectGrace_preservesIdleClock() {
        let id = sid()
        store.recordOutput(sessionID: id)
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        // Reconnect with a grace window; the tmux-redraw burst is ignored.
        store.markConnected(sessionID: id, grace: 5)
        store.recordOutput(sessionID: id)
        XCTAssertEqual(store.lastOutput(for: id), idleStamp,
                       "the post-reconnect redraw must not reset the clock")
    }

    func test_outputAfterGrace_advancesClock() {
        let id = sid()
        store.recordOutput(sessionID: id)
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        // Grace already elapsed (negative window) → real output counts again.
        store.markConnected(sessionID: id, grace: -1)
        Thread.sleep(forTimeInterval: 0.02)
        store.recordOutput(sessionID: id)
        XCTAssertGreaterThan(store.lastOutput(for: id)!, idleStamp,
                       "genuine output after the grace window must advance the clock")
    }

    func test_firstConnect_seedsClockImmediately() {
        let id = sid()
        // No prior reading → first connect seeds now and allows output.
        store.markConnected(sessionID: id)
        XCTAssertNotNil(store.lastOutput(for: id),
                        "first connect seeds the idle clock so a fresh session has a baseline")
    }
}
