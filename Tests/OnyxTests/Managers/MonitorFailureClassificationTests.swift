import XCTest
@testable import OnyxLib

/// A failed stats poll has to be told apart from a failed *connection*.
/// Getting this wrong is what turns one bad poll into a storm: every
/// misreported failure marks a healthy master suspect, which provokes a
/// smoke test, which opens another channel on the connection that just
/// said it had none spare.
final class MonitorFailureClassificationTests: XCTestCase {

    func testSuccessIsNotAFailure() {
        XCTAssertNil(MonitorManager.classify(exit: 0, stderr: "", timedOut: false))
    }

    func testOurOwnTimeoutIsNotEvidenceAboutTheConnection() {
        let failure = MonitorManager.classify(exit: 15, stderr: "", timedOut: true)
        XCTAssertEqual(failure, .timedOut)
        XCTAssertFalse(failure?.isTransport ?? true,
                       "we killed it — that says nothing about the link")
    }

    /// The signature of a connection that is UP but out of session slots:
    /// existing terminals keep working, new commands are refused.
    func testSessionLimitIsCapacityNotTransport() {
        let stderr = "mux_client_request_session: session request failed: Session open refused by peer"
        let failure = MonitorManager.classify(exit: 255, stderr: stderr, timedOut: false)
        guard case .noChannel(let detail)? = failure else {
            return XCTFail("expected .noChannel, got \(String(describing: failure))")
        }
        XCTAssertTrue(detail.contains("session request failed"))
        XCTAssertFalse(failure?.isTransport ?? true,
                       "a full connection must not be reported as a dead one")
    }

    func testAdministrativelyProhibitedIsCapacity() {
        let stderr = "channel 0: open failed: administratively prohibited: open failed"
        let failure = MonitorManager.classify(exit: 255, stderr: stderr, timedOut: false)
        XCTAssertFalse(failure?.isTransport ?? true)
    }

    func testRealTransportFailureIsReportedAsSuch() {
        let stderr = "ssh: connect to host example.com port 22: Operation timed out"
        let failure = MonitorManager.classify(exit: 255, stderr: stderr, timedOut: false)
        XCTAssertTrue(failure?.isTransport ?? false)
        XCTAssertEqual(failure, .transport("ssh: connect to host example.com port 22: Operation timed out"))
    }

    // MARK: - Messages carry ssh's own words

    func testTransportMessageIncludesStderr() {
        let msg = MonitorManager.message(
            for: .transport("ssh: Could not resolve hostname nope"), exit: 255)
        XCTAssertTrue(msg.contains("Could not resolve hostname"),
                      "the reason must reach the user; 'code 255' alone is unactionable")
        XCTAssertTrue(msg.contains("255"))
    }

    func testTransportMessageFallsBackWhenSshSaidNothing() {
        let msg = MonitorManager.message(for: .transport(""), exit: 255)
        XCTAssertEqual(msg, "SSH connection failed (code 255)")
    }

    func testCapacityMessageExplainsWhyTerminalsStillWork() {
        let msg = MonitorManager.message(for: .noChannel("session request failed"), exit: 255)
        XCTAssertTrue(msg.lowercased().contains("maxsessions"))
        XCTAssertTrue(msg.lowercased().contains("existing terminals"),
                      "must explain the exact thing the user observes")
    }

    // MARK: - stderr tidying

    func testFirstMeaningfulLineSkipsBlanksAndKnownNoise() {
        let stderr = """

        Warning: Permanently added 'host' (ED25519) to the list of known hosts.
        ssh: connect to host h port 22: No route to host
        """
        XCTAssertEqual(MonitorManager.firstMeaningfulLine(stderr),
                       "ssh: connect to host h port 22: No route to host")
    }

    func testFirstMeaningfulLineTruncatesRunawayOutput() {
        let line = MonitorManager.firstMeaningfulLine(String(repeating: "x", count: 500))
        XCTAssertLessThanOrEqual(line.count, 161)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testFirstMeaningfulLineOfEmptyStderr() {
        XCTAssertEqual(MonitorManager.firstMeaningfulLine("   \n\n"), "")
    }
}
