import XCTest
@testable import OnyxLib

/// Pinning tests for SSHProcess — locks in the invariants that
/// docs/ssh-connection-leak.md depends on. We don't actually shell out
/// to ssh here (that'd need a real host); we verify the helper exists,
/// has the expected API surface, and handles edge cases that previously
/// caused leaks.
final class SSHProcessShapeTests: XCTestCase {

    /// `findMasterPIDs` must return an empty array for a path that
    /// doesn't exist — not crash, not throw. Used by the SSHKeeper
    /// cleanup paths and the slot-establish "kill old master before
    /// replacing" guard.
    func test_findMasterPIDs_missingPathReturnsEmpty() {
        let result = SSHProcess.findMasterPIDs(
            socketPath: "/tmp/onyx-test-nonexistent-\(UUID().uuidString)"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// `killMaster` must be safe to call on a non-existent path. We
    /// call it as a no-op cleanup from many code paths and it must
    /// never block or throw.
    func test_killMaster_missingPathIsNoOp() {
        let nonexistent = "/tmp/onyx-test-nonexistent-\(UUID().uuidString)"
        // Just verifying it returns within a reasonable bound.
        let start = Date()
        SSHProcess.killMaster(at: nonexistent, userHost: "noone@127.0.0.1")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "killMaster on a missing path should return quickly; took \(elapsed)s")
    }

    /// SSHProcess.run with an obviously-bad command must return a
    /// non-zero exit within the timeout. Pinning the SIGKILL escalation
    /// contract — we never want this call to block longer than
    /// softTimeout + ~1s no matter how broken the input is.
    func test_run_returnsWithinTimeoutOnBadCommand() {
        let start = Date()
        let result = SSHProcess.run(
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=1",
             "definitely-not-a-real-host-xyz", "true"],
            softTimeout: 3
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "SSHProcess.run must respect softTimeout + ~1s; took \(elapsed)s")
        XCTAssertNotEqual(result.exit, 0, "bad host shouldn't return success")
    }
}
