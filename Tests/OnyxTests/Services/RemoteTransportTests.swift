import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// The seam every remote call goes through (docs/ios-plan.md, phase 1).
/// The rules about hostile shells live in the protocol's extension, so
/// they hold for every transport; these pin them with a fake one, then
/// run the Mac's ProcessTransport against the local host for real.
final class RemoteTransportTests: XCTestCase {

    /// Answers each invocation from a script of replies, and remembers
    /// what it was asked.
    final class FakeTransport: RemoteTransport {
        let name = "fake"
        var replies: [RemoteOutput]
        var asked: [RemoteInvocation] = []

        init(_ replies: [RemoteOutput]) { self.replies = replies }

        func execute(_ invocation: RemoteInvocation, on host: HostConfig,
                     timeout: TimeInterval, label: String) -> RemoteOutput {
            asked.append(invocation)
            return replies.isEmpty ? .failed("no reply") : replies.removeFirst()
        }

        func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
                   label: String, onOutput: @escaping (String) -> Void,
                   onExit: @escaping (Int32) -> Void) -> RemoteJob {
            fatalError("not used")
        }

        func upload(_ localPath: String, to remotePath: String, on host: HostConfig,
                    recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput { .failed("") }

        func download(_ remotePath: String, to localPath: String, from host: HostConfig,
                      recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput { .failed("") }
    }

    private let remote = HostConfig(label: "box", ssh: SSHConfig(host: "box.example", user: "me"))
    private let marker = RemoteScript.executionMarker

    private func ok(_ text: String) -> RemoteOutput {
        RemoteOutput(exit: 0, stdout: "\(text)\n\(marker)\n", stderr: "", timedOut: false)
    }

    // MARK: - The fallback

    func testAPipeThatWorksIsAllItTakes() {
        let t = FakeTransport([ok("hello")])
        let run = t.runScript("echo hello", on: remote, label: "t")
        XCTAssertEqual(run.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(t.asked, [.script("echo hello", terminal: false)])
    }

    /// No marker over a pipe is the noexec signature: try a terminal.
    func testNoMarkerOverAPipeRetriesWithATerminal() {
        let echoedNotRun = RemoteOutput(exit: 0, stdout: "echo hello\n", stderr: "", timedOut: false)
        let t = FakeTransport([echoedNotRun, ok("hello")])
        let run = t.runScript("echo hello", on: remote, label: "t")
        XCTAssertNotNil(run.cleaned)
        XCTAssertEqual(t.asked, [.script("echo hello", terminal: false),
                                 .script("echo hello", terminal: true)])
    }

    /// The failure reported is the one that got further.
    func testTheBetterFailureIsTheOneReported() {
        let banner = RemoteOutput(exit: 1, stdout: "Welcome to box\nlots of banner text here\n",
                                  stderr: "", timedOut: false)
        let t = FakeTransport([banner, .failed("")])
        let run = t.runScript("x", on: remote, label: "t")
        XCTAssertNil(run.cleaned)
        XCTAssertTrue(run.hadOutput, "the pipe attempt's banner is the better evidence")
    }

    func testALocalHostRunsOnce() {
        let t = FakeTransport([RemoteOutput(exit: 0, stdout: "", stderr: "", timedOut: false)])
        _ = t.runScript("x", on: .localhost, label: "t")
        XCTAssertEqual(t.asked.count, 1)
    }

    func testDeliveriesAreRespected() {
        let t = FakeTransport([ok("a"), ok("b")])
        _ = t.runScript("a", on: remote, delivery: .terminal, label: "t")
        _ = t.runScript("b", on: remote, delivery: .pipe, label: "t")
        XCTAssertEqual(t.asked, [.script("a", terminal: true), .script("b", terminal: false)])
    }

    func testTheFailureDetailSaysWhatHappened() {
        XCTAssertEqual(RemoteRun(RemoteOutput(exit: -1, stdout: "", stderr: "", timedOut: true)).failureDetail,
                       "no answer within the time budget")
        XCTAssertEqual(RemoteRun(RemoteOutput(exit: 255, stdout: "", stderr: "", timedOut: false)).failureDetail,
                       "no output at all (exit 255)")
    }

    func testCombinedIsStdoutThenStderr() {
        XCTAssertEqual(RemoteOutput(exit: 0, stdout: "out", stderr: "err", timedOut: false).combined, "out\nerr")
        XCTAssertEqual(RemoteOutput(exit: 0, stdout: "out", stderr: "", timedOut: false).combined, "out")
    }

    // MARK: - LineBuffer

    func testLinesWaitForTheirNewline() {
        let b = LineBuffer()
        XCTAssertEqual(b.append("/a/b"), [])
        XCTAssertEqual(b.append("/c\n/d"), ["/a/b/c"])
        XCTAssertEqual(b.append("\n"), ["/d"])
        XCTAssertEqual(b.append("x\ny\n"), ["x", "y"])
    }

    // MARK: - ProcessTransport, for real, on this Mac

    private func transport() -> (RemoteTransport, AppState) {
        let app = AppState()
        return (app.transport, app)
    }

    func testAScriptRunsLocally() {
        let (t, app) = transport()
        let run = t.runScript("echo onyx-$((40+2))", on: .localhost, label: "test")
        XCTAssertEqual(run.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), "onyx-42")
        _ = app
    }

    func testACommandRunsLocally() {
        let (t, app) = transport()
        let out = t.runCommand("echo out; echo err >&2; exit 3", on: .localhost, label: "test")
        XCTAssertEqual(out.exit, 3)
        XCTAssertTrue(out.stdout.contains("out"))
        XCTAssertEqual(out.stderr, "err")
        _ = app
    }

    func testFilesCopyLocally() throws {
        let (t, app) = transport()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        try "payload".write(to: src, atomically: true, encoding: .utf8)
        let up = dir.appendingPathComponent("b.txt")
        XCTAssertEqual(t.upload(src.path, to: up.path, on: .localhost, recursive: false,
                                timeout: 10, label: "test").exit, 0)
        let down = dir.appendingPathComponent("c.txt")
        XCTAssertEqual(t.download(up.path, to: down.path, from: .localhost, recursive: false,
                                  timeout: 10, label: "test").exit, 0)
        XCTAssertEqual(try String(contentsOf: down, encoding: .utf8), "payload")
        _ = app
    }

    func testAJobStreamsItsOutput() {
        let (t, app) = transport()
        let done = expectation(description: "exit")
        var seen: [String] = []
        let buffer = LineBuffer()
        let lock = NSLock()
        t.start(.script("for i in 1 2 3; do echo line$i; done", terminal: false), on: .localhost,
                timeout: 10, label: "test",
                onOutput: { text in lock.lock(); seen += buffer.append(text); lock.unlock() },
                onExit: { code in XCTAssertEqual(code, 0); done.fulfill() })
        wait(for: [done], timeout: 10)
        XCTAssertEqual(seen.filter { $0.hasPrefix("line") }, ["line1", "line2", "line3"])
        _ = app
    }

    func testACancelledJobEnds() {
        let (t, app) = transport()
        let done = expectation(description: "exit")
        let job = t.start(.command("sleep 30"), on: .localhost, timeout: 60, label: "test",
                          onOutput: { _ in }, onExit: { _ in done.fulfill() })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { job.cancel() }
        wait(for: [done], timeout: 10)
        _ = app
    }
}
