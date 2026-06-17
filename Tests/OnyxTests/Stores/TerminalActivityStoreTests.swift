import XCTest
@testable import OnyxLib

final class TerminalActivityStoreTests: XCTestCase {

    private var store: TerminalActivityStore { TerminalActivityStore.shared }

    override func tearDown() {
        store.forget(sessionID: "s1")
        store.forget(sessionID: "s2")
        super.tearDown()
    }

    func test_unknownSession_isNil() {
        XCTAssertNil(store.lastOutput(for: "never-seen"))
    }

    func test_recordOutput_setsTimestamp() {
        let before = Date()
        store.recordOutput(sessionID: "s1")
        let stamp = store.lastOutput(for: "s1")
        XCTAssertNotNil(stamp)
        XCTAssertGreaterThanOrEqual(stamp!.timeIntervalSince(before), 0)
    }

    func test_recordOutput_advancesTimestamp() {
        store.recordOutput(sessionID: "s1")
        let first = store.lastOutput(for: "s1")!
        // Force a measurable gap, then record again.
        Thread.sleep(forTimeInterval: 0.02)
        store.recordOutput(sessionID: "s1")
        let second = store.lastOutput(for: "s1")!
        XCTAssertGreaterThan(second, first)
    }

    func test_sessionsAreIndependent() {
        store.recordOutput(sessionID: "s1")
        XCTAssertNotNil(store.lastOutput(for: "s1"))
        XCTAssertNil(store.lastOutput(for: "s2"))
    }

    func test_forget_clearsSession() {
        store.recordOutput(sessionID: "s1")
        XCTAssertNotNil(store.lastOutput(for: "s1"))
        store.forget(sessionID: "s1")
        XCTAssertNil(store.lastOutput(for: "s1"))
    }
}
