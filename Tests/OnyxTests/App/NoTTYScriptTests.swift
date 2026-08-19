import XCTest
@testable import OnyxLib

/// A terminal on the far end is what makes remote scripts fragile: a ~1KB
/// input queue, a line discipline that can hand the shell a mangled tail,
/// and an echo that pollutes the output. `-tt` is only there to defeat
/// noexec shells, so it should be the FALLBACK, not the default.
final class NoTTYScriptTests: XCTestCase {

    private func remoteHost() -> HostConfig {
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        host.ssh.user = "michael"
        return host
    }

    func testPipedFormAsksForNoTerminal() {
        let (cmd, args, stdin) = AppState().remoteScriptNoTTY("echo hi", host: remoteHost())
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-T"), "must explicitly disable the tty")
        XCTAssertFalse(args.contains("-tt"))
        XCTAssertNotNil(stdin)
        XCTAssertTrue(stdin?.contains("echo hi") ?? false)
    }

    /// No tty means no echo to suppress and no session to exit — the shell
    /// ends at EOF. Sending `stty`/`exit` anyway would just be noise the
    /// parser has to survive.
    func testPipedFormDropsTheTerminalCeremony() {
        let (_, _, stdin) = AppState().remoteScriptNoTTY("echo hi", host: remoteHost())
        XCTAssertFalse(stdin?.contains("stty -echo") ?? true)
        XCTAssertFalse(stdin?.hasSuffix("exit\n\n") ?? true)
    }

    /// The execution proof has to survive the change of transport — it's
    /// what tells the fallback whether the pipe worked.
    func testPipedFormKeepsTheExecutionMarker() {
        let (_, _, stdin) = AppState().remoteScriptNoTTY("echo hi", host: remoteHost())
        XCTAssertTrue(stdin?.contains("---ONYX-OK-$((1+1))---") ?? false)
    }

    func testTTYFormIsUnchanged() {
        let (_, args, stdin) = AppState().remoteScript("echo hi", host: remoteHost())
        XCTAssertTrue(args.contains("-tt"))
        XCTAssertTrue(stdin?.contains("stty -echo") ?? false)
        XCTAssertTrue(stdin?.contains("exit") ?? false)
    }

    /// Both forms still ride the connection pair — the transport changed,
    /// the two-connection cap did not.
    func testBothFormsStayOnTheMux() {
        let host = remoteHost()
        for args in [AppState().remoteScriptNoTTY("x", host: host).args,
                     AppState().remoteScript("x", host: host).args] {
            XCTAssertTrue(args.contains("ControlMaster=no"), "\(args)")
            XCTAssertTrue(args.contains { $0.hasPrefix("ControlPath=") }, "\(args)")
        }
    }

    func testLocalHostIsUnaffected() {
        let (cmd, args, stdin) = AppState().remoteScriptNoTTY("echo hi", host: .localhost)
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertEqual(args.first, "-c")
        XCTAssertNil(stdin)
    }
}
