import XCTest
@testable import OnyxLib

final class RemoteScriptTests: XCTestCase {

    // MARK: - wrap

    func testWrap_includesPathSetup() {
        let wrapped = RemoteScript.wrap("echo hi")
        XCTAssertTrue(wrapped.contains("PATH="),
                      "wrapped script should set PATH; got: \(wrapped)")
        XCTAssertTrue(wrapped.contains("/usr/bin"),
                      "wrapped script should include /usr/bin in PATH")
        XCTAssertTrue(wrapped.contains("/opt/homebrew/bin"),
                      "wrapped script should include /opt/homebrew/bin for Apple Silicon Homebrew")
    }

    func testWrap_disablesVerboseAndXtrace() {
        // `set +vx` defends against a remote profile that turns these on.
        let wrapped = RemoteScript.wrap("echo hi")
        XCTAssertTrue(wrapped.contains("set +vx"),
                      "wrapped script should disable verbose/xtrace; got: \(wrapped)")
    }

    func testWrap_appendsExecutionMarker() {
        let wrapped = RemoteScript.wrap("echo hi")
        // The marker uses shell arithmetic so a noexec shell can't fake it
        // by echoing the source.
        XCTAssertTrue(wrapped.contains("$((1+1))"),
                      "wrapped script must include the unevaluated marker form so a running shell evaluates it; got: \(wrapped)")
    }

    func testWrap_includesCallerScriptVerbatim() {
        // The wrapper must not corrupt the caller's commands.
        let body = "git -C /tmp/foo status --porcelain && uptime"
        let wrapped = RemoteScript.wrap(body)
        XCTAssertTrue(wrapped.contains(body),
                      "wrapped script must contain caller body verbatim; got: \(wrapped)")
    }

    // MARK: - executionVerified

    func testExecutionVerified_trueForRunningShellOutput() {
        let output = "some output\n---ONYX-OK-2---\n"
        XCTAssertTrue(RemoteScript.executionVerified(in: output))
    }

    func testExecutionVerified_falseWhenMarkerMissing() {
        let output = "some output without marker\n"
        XCTAssertFalse(RemoteScript.executionVerified(in: output))
    }

    func testExecutionVerified_falseForNoexecEchoedSource() {
        // A noexec+verbose shell echoes the source verbatim, including
        // `echo "---ONYX-OK-$((1+1))---"`. The literal "2" is never produced
        // because the shell never evaluates the arithmetic.
        let output = """
        set +vx 2>/dev/null
        PATH=...
        echo "---UPTIME---"; uptime
        echo "---CPU---"; ...
        echo "---ONYX-OK-$((1+1))---"
        """
        XCTAssertFalse(RemoteScript.executionVerified(in: output),
                       "echoed source should NOT be verified — it's the exact case we need to detect")
    }

    // MARK: - cleanedOutput

    func testCleanedOutput_stripsCarriageReturns() {
        // ssh -tt produces \r\n endings.
        let raw = "line one\r\nline two\r\n---ONYX-OK-2---\r\n"
        let cleaned = RemoteScript.cleanedOutput(raw)
        XCTAssertFalse(cleaned.contains("\r"),
                       "cleaned output must not contain \\r; got: \(cleaned)")
    }

    func testCleanedOutput_removesExecutionMarker() {
        let raw = "useful output\n---ONYX-OK-2---\n"
        let cleaned = RemoteScript.cleanedOutput(raw)
        XCTAssertFalse(cleaned.contains("---ONYX-OK-2---"),
                       "cleaned output must remove the marker so callers don't see it as data")
        XCTAssertTrue(cleaned.contains("useful output"),
                      "cleaned output must preserve actual content")
    }

    func testCleanedOutput_idempotent() {
        // Calling twice should be safe.
        let raw = "data\r\n---ONYX-OK-2---\r\n"
        let once = RemoteScript.cleanedOutput(raw)
        let twice = RemoteScript.cleanedOutput(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - diagnostic message

    func testNonExecutionDiagnostic_isUserActionable() {
        // The message should mention the likely cause so a user has
        // somewhere to start. We don't lock the exact wording, just
        // that it points at the real culprit.
        let msg = RemoteScript.nonExecutionDiagnostic
        XCTAssertTrue(msg.contains("set -n") || msg.contains("noexec") || msg.contains("dry-run"),
                      "diagnostic should name the noexec mode as the likely cause; got: \(msg)")
    }
}
