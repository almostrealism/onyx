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

    func testCleanedOutput_truncatesShellNoiseAfterMarker() {
        // ssh -tt prints a trailing shell prompt and `exit` echo after
        // our `exit` command. Callers that read the last section
        // (extractSection with end:nil — git toplevel, commit diff)
        // would otherwise pick up that noise. cleanedOutput must drop
        // everything from the marker onwards, not just the marker line.
        let raw = """
        useful output
        ---GIT_TOPLEVEL---
        /repo/path
        ---ONYX-OK-2---
        user@host:~$ exit
        logout
        Connection to host closed.
        """
        let cleaned = RemoteScript.cleanedOutput(raw)
        XCTAssertFalse(cleaned.contains("user@host"),
                       "trailing prompt noise must be cut: \(cleaned)")
        XCTAssertFalse(cleaned.contains("Connection to host"),
                       "trailing connection-close message must be cut: \(cleaned)")
        XCTAssertTrue(cleaned.contains("/repo/path"),
                      "real script output before the marker must be preserved")
    }

    // MARK: - stripSourceEcho

    func testStripSourceEcho_dropsLeadingScriptEchoBlock() {
        // Realistic case: ssh -tt remoted us our own script back before
        // stty -echo could take effect. The runtime body comes after the
        // last `$((1+1))` line — everything up to and including that line
        // is parser bait.
        let raw = """
        set +vx 2>/dev/null
        PS1=''; PS2=''; PROMPT_COMMAND=''
        PATH="${PATH:-}:/usr/bin"
        echo "---UPTIME---"; uptime
        echo "---CPU---"; top -bn1 | head -5
        echo "---ONYX-OK-$((1+1))---"
        ---UPTIME---
         14:23:45 up 7 days, load average: 0.42, 0.31, 0.28
        ---CPU---
        %Cpu(s):  3.2 us,  1.0 sy,  0.0 ni, 95.6 id
        """
        let cleaned = RemoteScript.stripSourceEcho(raw)
        XCTAssertFalse(cleaned.contains("echo \"---UPTIME---\""),
                       "source-echo line must be cut: \(cleaned)")
        XCTAssertFalse(cleaned.contains("PS1=''"),
                       "PS1 setup line is source echo, must be cut")
        XCTAssertTrue(cleaned.contains("---UPTIME---"),
                      "runtime marker (no `echo` prefix) must survive")
        XCTAssertTrue(cleaned.contains("14:23:45 up 7 days"),
                      "actual uptime data must survive")
    }

    func testStripSourceEcho_returnsInputWhenEchoWasSuppressed() {
        // If stty -echo did its job and the source never echoed, we won't
        // see `$((1+1))` in the output. The function must be a no-op then.
        let clean = """
        ---UPTIME---
         14:23:45 up 7 days, load average: 0.42, 0.31, 0.28
        ---CPU---
        %Cpu(s):  3.2 us
        """
        XCTAssertEqual(RemoteScript.stripSourceEcho(clean), clean)
    }

    func testStripSourceEcho_handlesMultipleEchoBlocks() {
        // If for some reason the source echoed twice (rare but possible
        // on flaky remotes), we want to cut everything up to the LAST
        // `$((1+1))` so the parser only sees the genuine runtime output.
        let raw = """
        echo "first"; echo "---ONYX-OK-$((1+1))---"
        garbage that shouldn't be parsed
        echo "second"; echo "---ONYX-OK-$((1+1))---"
        ---CPU---
        real data
        """
        let cleaned = RemoteScript.stripSourceEcho(raw)
        XCTAssertFalse(cleaned.contains("garbage"),
                       "anything between echo blocks must also be cut: \(cleaned)")
        XCTAssertTrue(cleaned.contains("real data"))
    }

    func testCleanedOutput_stripsSourceEchoBeforeTruncating() {
        // The combined wrap that callers actually use: ssh -tt produces
        // source echo, runtime output, then the marker. cleanedOutput
        // should remove BOTH the leading source-echo block AND the
        // trailing marker, leaving only runtime content.
        let raw = PollutedOutputFixture.fullEchoThenRuntime(
            script: "uptime",
            runtime: "14:23:45 up 7 days, load average: 0.4, 0.3, 0.2"
        )
        let cleaned = RemoteScript.cleanedOutput(raw)
        XCTAssertFalse(cleaned.contains("PS1=''"),
                       "source echo must be stripped: \(cleaned)")
        XCTAssertFalse(cleaned.contains("---ONYX-OK"),
                       "marker must be stripped: \(cleaned)")
        XCTAssertTrue(cleaned.contains("14:23:45 up 7 days"),
                      "real runtime must survive")
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
