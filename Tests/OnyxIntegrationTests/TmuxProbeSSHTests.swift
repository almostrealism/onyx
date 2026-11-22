import XCTest
@testable import OnyxCore
@testable import OnyxLib
import OnyxTestSupport

/// A host without tmux, as the Mac meets it: through real `ssh` against a
/// private sshd (LocalSSHD).
final class TmuxProbeSSHTests: XCTestCase {

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
                          ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port,
                                         identityFile: sshd.clientKey.path))
    }

    override func tearDown() {
        AppState.testSSHOptions = []
        sshd?.stop()
        super.tearDown()
    }

    /// The signal Onyx waits for: a command the host doesn't have exits
    /// 127, and ssh hands that back unchanged — in the shape the session
    /// attach uses (`exec $SHELL -lc '…'`).
    func testAMissingCommandComesBackAs127() {
        let out = app.transport.runCommand("onyx-no-such-tmux new-session -A -s x", on: host, label: "t")
        XCTAssertEqual(out.exit, 127, "\(out.stderr)\n\(sshd.log)")
    }

    func testTheProbeAnswersOverAPipe() throws {
        let run = app.transport.runScript(TmuxInstall.probeScript, on: host, delivery: .pipe, label: "t")
        let probe = try XCTUnwrap(run.cleaned.flatMap(TmuxInstall.parse), "\(run.failureDetail)\n\(sshd.log)")
        XCTAssertEqual(probe.system, "Darwin")
    }

    /// The noexec fallback echoes the script; the echo must not be taken
    /// for the answer.
    func testTheProbeAnswersInATerminal() throws {
        let run = app.transport.runScript(TmuxInstall.probeScript, on: host, delivery: .terminal, label: "t")
        let probe = try XCTUnwrap(run.cleaned.flatMap(TmuxInstall.parse), "\(run.failureDetail)\n\(sshd.log)")
        XCTAssertEqual(probe.system, "Darwin")
    }
}
