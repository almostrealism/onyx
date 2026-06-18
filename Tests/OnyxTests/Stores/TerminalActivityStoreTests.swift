import XCTest
@testable import OnyxLib

final class TerminalActivityStoreTests: XCTestCase {

    private var store: TerminalActivityStore { TerminalActivityStore.shared }

    // Unique session ids per test keep the shared singleton's state from
    // leaking between cases (there's no public reset).
    private func sid(_ name: String = #function) -> String { "test-\(name)-\(UUID().uuidString)" }

    func test_unknownSession_isNil() {
        XCTAssertNil(store.lastOutput(for: sid()))
    }

    func test_firstContent_seedsClock() {
        let id = sid()
        let before = Date()
        store.recordContent(sessionID: id, contentHash: 1)
        let stamp = store.lastOutput(for: id)
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual(stamp!.timeIntervalSince(before), 0)
    }

    func test_sameContent_doesNotAdvanceClock() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 42)
        let first = store.lastOutput(for: id)!
        Thread.sleep(forTimeInterval: 0.02)
        // Same hash (e.g. a tmux status-bar tick that we've already excluded,
        // or a redraw of identical content) — clock must NOT move.
        store.recordContent(sessionID: id, contentHash: 42)
        XCTAssertEqual(store.lastOutput(for: id), first,
                       "unchanged content must not reset the idle clock")
    }

    func test_changedContent_advancesClock() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 1)
        let first = store.lastOutput(for: id)!
        Thread.sleep(forTimeInterval: 0.02)
        store.recordContent(sessionID: id, contentHash: 2)
        XCTAssertGreaterThan(store.lastOutput(for: id)!, first,
                             "changed content advances the clock")
    }

    func test_sessionsAreIndependent() {
        let a = sid(), b = sid()
        store.recordContent(sessionID: a, contentHash: 1)
        XCTAssertNotNil(store.lastOutput(for: a))
        XCTAssertNil(store.lastOutput(for: b))
    }

    // MARK: - Disconnect / reconnect suppression

    func test_disconnected_ignoresContent() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 1)
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        Thread.sleep(forTimeInterval: 0.02)
        // Garbage/partial content while disconnected must be ignored.
        store.recordContent(sessionID: id, contentHash: 999)
        XCTAssertEqual(store.lastOutput(for: id), idleStamp,
                       "content reported while disconnected must not move the clock")
    }

    func test_reconnectGrace_ignoresRedraw() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 1)
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        // Reconnect with a grace window: even a *different* hash (the redraw
        // settling) is ignored until grace passes.
        store.markConnected(sessionID: id, grace: 5)
        store.recordContent(sessionID: id, contentHash: 7)
        XCTAssertEqual(store.lastOutput(for: id), idleStamp,
                       "post-reconnect redraw within grace must not reset the clock")
    }

    func test_changeAfterGrace_advancesClock() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 1)
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        store.markConnected(sessionID: id, grace: -1)  // grace already elapsed
        Thread.sleep(forTimeInterval: 0.02)
        store.recordContent(sessionID: id, contentHash: 2)
        XCTAssertGreaterThan(store.lastOutput(for: id)!, idleStamp,
                             "genuine change after the grace window advances the clock")
    }

    func test_restoredContentAfterGrace_preservesClock() {
        let id = sid()
        store.recordContent(sessionID: id, contentHash: 100)  // baseline
        let idleStamp = store.lastOutput(for: id)!
        store.markDisconnected(sessionID: id)
        store.markConnected(sessionID: id, grace: -1)
        Thread.sleep(forTimeInterval: 0.02)
        // tmux restored the same screen → same hash → clock preserved.
        store.recordContent(sessionID: id, contentHash: 100)
        XCTAssertEqual(store.lastOutput(for: id), idleStamp,
                       "a restored identical screen after reconnect keeps the idle time")
    }
}
