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

    /// The zsh-glob regression: a broken stats script exits non-zero
    /// through a perfectly healthy connection. ssh reserves 255 for its
    /// own failures, so anything else is the remote command's status and
    /// must not be reported as a connection problem.
    func testRemoteScriptFailureIsNotATransportFailure() {
        let stderr = "zsh:4: no matches found: /sys/class/drm/card*/device"
        let failure = MonitorManager.classify(exit: 1, stderr: stderr, timedOut: false)
        guard case .remoteScript(let detail)? = failure else {
            return XCTFail("expected .remoteScript, got \(String(describing: failure))")
        }
        XCTAssertTrue(detail.contains("no matches found"))
        XCTAssertFalse(failure?.isTransport ?? true)
        XCTAssertTrue(MonitorManager.message(for: failure!, exit: 1).contains("no matches found"),
                      "the shell's own complaint is the whole diagnosis")
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

    // MARK: - Data beats the exit code

    /// The regression this replaced: a host whose stats command runs long
    /// still sends its numbers before we kill it. Classifying first threw
    /// those away and called a working host broken. Usability of the
    /// OUTPUT decides — the exit code only explains a failure, it doesn't
    /// define one.
    func testTimedOutRunWithUsableOutputIsStillUsable() {
        let output = """
        ---UPTIME---
         12:00:00 up 3 days, load average: 0.40, 0.30, 0.20
        ---CPU---
        %Cpu(s):  4.0 us,  1.0 sy,  0.0 ni, 95.0 id
        ---MEM---
        Mem:          16000        4000       12000
        ---GPU---
        N/A
        """
        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        XCTAssertTrue(MonitorManager.isUsable(sample!),
                      "CPU and memory came back — this poll worked, whatever the exit code")
    }

    /// The inverse: output arrived but nothing in it was a metric. That's
    /// a failure even if the process exited 0.
    func testOutputWithNoMetricsIsNotUsable() {
        let sample = MonitorManager.parse(output: "---UPTIME---\n---CPU---\n---MEM---\n---GPU---\nN/A")
        XCTAssertNotNil(sample, "parse always returns a sample…")
        XCTAssertFalse(MonitorManager.isUsable(sample!), "…but an empty one is not a success")
    }

    func testAnySingleMetricCountsAsUsable() {
        let loadOnly = MonitorManager.parse(
            output: "---UPTIME---\n 12:00:00 up 1 day, load average: 0.10, 0.20, 0.30")
        XCTAssertTrue(MonitorManager.isUsable(loadOnly!),
                      "a host with unparseable top still reports load — don't discard it")
    }

    // MARK: - What the host actually said

    /// The real failure, verbatim: a `!` in the script triggered zsh
    /// history expansion in the interactive remote shell, which discarded
    /// the whole line and left the session waiting. The host TOLD us
    /// this — over the PTY, mixed into stdout — and we reported a timeout
    /// instead. Whatever else we say, the host's own words must reach the
    /// user.
    func testRemoteComplaintFindsTheHostsOwnError() {
        let output = "\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[0m  worker@Mac-Studio ~ % "
            + "zsh: event not found: 0\r\n"
        let complaint = MonitorManager.remoteComplaint(in: output)
        XCTAssertNotNil(complaint)
        // The prompt the shell echoed stays attached — it's evidence in
        // its own right (an interactive shell echoing a prompt at us), and
        // guessing where a prompt ends would mangle real output like
        // "CPU usage: 13% user".
        XCTAssertTrue(complaint?.contains("zsh: event not found: 0") ?? false,
                      "got: \(complaint ?? "nil")")
        XCTAssertFalse(complaint?.contains("\u{1B}") ?? true, "escape sequences must be stripped")
        XCTAssertFalse(complaint?.contains("1m7m") ?? true, "escape *bodies* must be stripped too")
    }

    func testRemoteComplaintIgnoresOurOwnScaffolding() {
        let output = """
        ---UPTIME---
        ---CPU---
        bash: line 4: /sys/class/drm: No such file or directory
        ---ONYX-OK-2---
        """
        XCTAssertEqual(MonitorManager.remoteComplaint(in: output),
                       "bash: line 4: /sys/class/drm: No such file or directory")
    }

    func testRemoteComplaintIsNilWhenTheHostSaidNothing() {
        XCTAssertNil(MonitorManager.remoteComplaint(in: ""))
        XCTAssertNil(MonitorManager.remoteComplaint(in: "---UPTIME---\n---CPU---\n---ONYX-OK-2---"))
        // Prompt residue with no letters or digits isn't a message.
        XCTAssertNil(MonitorManager.remoteComplaint(in: "\u{1B}[0m%   \r\n"))
    }

    /// The message must carry it, not summarise it away.
    func testTimeoutMessageQuotesTheHostWhenItSaidSomething() {
        let quiet = MonitorManager.message(for: .timedOut, exit: 15, remoteSaid: nil)
        XCTAssertTrue(quiet.contains("sent nothing back"),
                      "when the host really was silent, say exactly that")

        let spoke = MonitorManager.message(for: .timedOut, exit: 15,
                                           remoteSaid: "zsh: event not found: 0")
        XCTAssertTrue(spoke.contains("zsh: event not found: 0"),
                      "the host's complaint is the whole diagnosis — it must be in the message")
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
