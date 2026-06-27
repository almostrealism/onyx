import XCTest
@testable import OnyxLib

final class PollLoopTests: XCTestCase {

    func test_refresh_invokesTickOnMain() {
        var count = 0
        let loop = PollLoop(interval: 100) { count += 1 }
        loop.refresh()
        // refresh dispatches the tick to main async; pumping the run loop
        // (via a follow-on main-queue expectation) lets it run first.
        let exp = expectation(description: "tick ran")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(count, 1)
    }

    func test_startUnderXCTest_isNoOp() {
        // The managers rely on this: start() must NOT create a timer or fire
        // ticks under XCTest, so unit tests never kick off network polling.
        var count = 0
        let loop = PollLoop(interval: 0.01) { count += 1 }
        loop.start()
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(count, 0, "start() must be a no-op under XCTest")
    }

    func test_stop_isSafeBeforeStartAndIdempotent() {
        let loop = PollLoop(interval: 100) { }
        loop.stop()   // never started
        loop.stop()   // again — must not crash
    }
}
