import XCTest
@testable import OnyxCore
@testable import OnyxLib
import OnyxTestSupport

/// The Mac's transport — real `ssh` and `scp` processes — against a real
/// sshd (LocalSSHD), through the same RemoteTransport calls every manager
/// now makes. Nothing of the user's is touched: the server, its keys and
/// its known_hosts live in a temp folder.
final class ProcessTransportSSHTests: XCTestCase {

    private var sshd: LocalSSHD!
    private var app: AppState!
    private var host: HostConfig!

    override func setUpWithError() throws {
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable {
            throw XCTSkip(why.description)
        }
        AppState.testSSHOptions = sshd.sshOptions
        app = AppState()
        host = HostConfig(label: "local-sshd",
                          ssh: SSHConfig(host: "127.0.0.1", user: sshd.user, port: sshd.port,
                                         identityFile: sshd.clientKey.path))
    }

    override func tearDown() {
        AppState.testSSHOptions = []
        sshd?.stop()
        super.tearDown()
    }

    func testAScriptRunsOverAPipe() {
        let run = app.transport.runScript("echo remote-$((6*7))", on: host, delivery: .pipe, label: "t")
        XCTAssertEqual(run.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), "remote-42",
                       "\(run.failureDetail)\n\(sshd.log)")
    }

    func testAScriptRunsInATerminal() {
        let run = app.transport.runScript("echo tty-$((6*7))", on: host, delivery: .terminal, label: "t")
        XCTAssertTrue(run.cleaned?.contains("tty-42") == true, "\(run.failureDetail)\n\(sshd.log)")
    }

    func testACommandRunsInALoginShell() {
        let out = app.transport.runCommand("echo hi; exit 4", on: host, label: "t")
        XCTAssertEqual(out.exit, 4, out.stderr)
        XCTAssertTrue(out.stdout.contains("hi"))
    }

    func testFilesGoUpAndComeBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("up.txt")
        try "over the wire".write(to: src, atomically: true, encoding: .utf8)

        // Relative to the remote home — the path rule for transfers.
        let remote = ".onyx-transport-test-\(UUID().uuidString.prefix(8)).txt"
        defer { _ = app.transport.runCommand("rm -f ~/\(remote)", on: host, label: "cleanup") }
        let up = app.transport.upload(src.path, to: remote, on: host, recursive: false,
                                      timeout: 20, label: "t")
        XCTAssertEqual(up.exit, 0, up.stderr)

        let back = dir.appendingPathComponent("down.txt")
        let down = app.transport.download(remote, to: back.path, from: host, recursive: false,
                                          timeout: 20, label: "t")
        XCTAssertEqual(down.exit, 0, down.stderr)
        XCTAssertEqual(try String(contentsOf: back, encoding: .utf8), "over the wire")
    }

    /// SharedStateSync tells "the file isn't there" from "I couldn't ask"
    /// by these exact conventions; a transport that broke them would read
    /// a dropped connection as a deleted file.
    func testAMissingFileIsNotAConnectionFailure() throws {
        let back = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let down = app.transport.download(".no-such-file-\(UUID().uuidString)", to: back.path, from: host,
                                          recursive: false, timeout: 20, label: "t")
        XCTAssertNotEqual(down.exit, 0)
        XCTAssertFalse(down.isTransportFailure)
        guard case .missing = SharedStateSync.classify(exit: down.exit, stderr: down.stderr) else {
            return XCTFail("classified as \(SharedStateSync.classify(exit: down.exit, stderr: down.stderr)): \(down.stderr)")
        }
    }

    func testAJobStreamsFromTheHost() {
        let done = expectation(description: "exit")
        let lines = LineBuffer()
        var seen: [String] = []
        let lock = NSLock()
        app.transport.start(.script("for i in 1 2 3; do echo row$i; done", terminal: false), on: host,
                            timeout: 20, label: "t",
                            onOutput: { t in lock.lock(); seen += lines.append(t); lock.unlock() },
                            onExit: { _ in done.fulfill() })
        wait(for: [done], timeout: 20)
        XCTAssertEqual(seen.filter { $0.hasPrefix("row") }, ["row1", "row2", "row3"])
    }
}
