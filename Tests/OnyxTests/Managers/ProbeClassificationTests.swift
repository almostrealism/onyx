import XCTest
@testable import OnyxLib

/// A failed probe used to mean exactly one thing: "install your SSH key".
/// Unconditionally — stderr was captured and never read. So a timeout, a
/// refused mux channel or a blip announced that the key was missing, on a
/// host the user was actively working on.
final class ProbeClassificationTests: XCTestCase {

    func testRealAuthRefusalIsAKeyProblem() {
        for stderr in [
            "michael@mac-studio: Permission denied (publickey,password,keyboard-interactive).",
            "Received disconnect from 10.0.0.4 port 22:2: Too many authentication failures",
            "No supported authentication methods available (server sent: publickey)",
        ] {
            XCTAssertEqual(OnyxTerminalView.classifyProbeFailure(stderr: stderr), .keyAuthFailed,
                           "should be a key problem: \(stderr)")
        }
    }

    /// Everything else is a reachability problem, and must NOT put a
    /// "install your SSH key" overlay over a working session.
    func testTransientFailuresAreNotKeyProblems() {
        for stderr in [
            "",                                                    // timed out, nothing said
            "ssh: connect to host mac-studio port 22: Operation timed out",
            "mux_client_request_session: session request failed: Session open refused by peer",
            "channel 0: open failed: administratively prohibited: open failed",
            "ssh: Could not resolve hostname mac-studio: nodename nor servname provided",
            "Connection closed by 10.0.0.4 port 22",
            "banner exchange: Connection to 10.0.0.4 port 22: invalid format",
        ] {
            XCTAssertEqual(OnyxTerminalView.classifyProbeFailure(stderr: stderr), .unreachable,
                           "must not claim the key is missing: \(stderr)")
        }
    }

    func testHostKeyVerificationIsTreatedAsAnAuthProblem() {
        // Not a missing key exactly, but it does need the user, and the
        // key-setup flow is where that conversation happens.
        XCTAssertEqual(
            OnyxTerminalView.classifyProbeFailure(stderr: "Host key verification failed."),
            .keyAuthFailed)
    }
}
