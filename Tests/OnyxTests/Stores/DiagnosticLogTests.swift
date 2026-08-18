import XCTest
@testable import OnyxLib

/// The in-app event window. Every bug this month was diagnosed by finding
/// out what the host actually said, and every time that meant asking for
/// `log show` output — a round trip that failed as often as it worked.
final class DiagnosticLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DiagnosticLog.shared.clear()
        drain()
    }

    /// record() hops to main; let it land.
    private func drain() {
        let done = expectation(description: "drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testNewestFirst() {
        DiagnosticLog.shared.record("ssh", "first")
        DiagnosticLog.shared.record("ssh", "second")
        drain()
        XCTAssertEqual(DiagnosticLog.shared.entries.first?.message, "second",
                       "the newest event is the one you're looking for")
    }

    func testFailuresAreMarked() {
        DiagnosticLog.shared.record("probe", "boom", failure: true)
        DiagnosticLog.shared.record("ssh", "fine")
        drain()
        XCTAssertTrue(DiagnosticLog.shared.entries.first { $0.message == "boom" }?.isFailure ?? false)
        XCTAssertFalse(DiagnosticLog.shared.entries.first { $0.message == "fine" }?.isFailure ?? true)
    }

    /// A window, not an archive — it must not grow without bound in an
    /// app that stays open for weeks.
    func testCapped() {
        for i in 0..<260 { DiagnosticLog.shared.record("ssh", "event \(i)") }
        drain()
        XCTAssertLessThanOrEqual(DiagnosticLog.shared.entries.count, 200)
        XCTAssertEqual(DiagnosticLog.shared.entries.first?.message, "event 259",
                       "trimming must drop the OLDEST, not the newest")
    }

    func testRecentAndSince() {
        let before = Date()
        DiagnosticLog.shared.record("ssh", "a")
        DiagnosticLog.shared.record("ssh", "b")
        drain()
        XCTAssertEqual(DiagnosticLog.shared.recent(1).count, 1)
        XCTAssertEqual(DiagnosticLog.shared.since(before).count, 2)
        XCTAssertEqual(DiagnosticLog.shared.since(Date().addingTimeInterval(60)).count, 0)
    }

    func testConcurrentRecordingIsSafe() {
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                DiagnosticLog.shared.record("ssh", "concurrent \(i)")
                group.leave()
            }
        }
        group.wait()
        drain()
        XCTAssertEqual(DiagnosticLog.shared.entries.count, 50)
    }
}
