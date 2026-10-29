import XCTest
@testable import OnyxCore
@testable import OnyxLib
import OnyxTestSupport

/// A host reached through another, end to end: the tunnel host's master is
/// a real one, and the tunneled host's commands go through it with
/// `ssh -W`. Both are the same private sshd — the tunneled host is just
/// asked for by the address the tunnel host would use.
final class TunnelSSHTests: XCTestCase {

    private var sshd: LocalSSHD!
    private var app: AppState!
    private var gateway: HostConfig!
    private var inner: HostConfig!

    override func setUpWithError() throws {
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable {
            throw XCTSkip(why.description)
        }
        AppState.testSSHOptions = sshd.sshOptions
        app = AppState()
        gateway = HostConfig(label: "gateway",
                             ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port,
                                            identityFile: sshd.clientKey.path))
        inner = HostConfig(label: "inner",
                           ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port,
                                          identityFile: sshd.clientKey.path),
                           tunnelHostID: gateway.id)
        app.hosts = [gateway, inner]
    }

    override func tearDown() {
        if let gateway, let app {
            let path = app.sshControlPath(for: gateway)
            _ = RemoteExec.shared.ssh(args: ["-o", "ControlPath=\(path)", "-O", "exit", "x"],
                                      softTimeout: 3, label: "test")
            try? FileManager.default.removeItem(atPath: path)
        }
        AppState.testSSHOptions = []
        sshd?.stop()
        super.tearDown()
    }

    /// The tunnel host's master, as its pair would start it.
    private func startGatewayMaster() {
        var args = ["-M", "-N", "-f", "-o", "ControlMaster=yes",
                    "-o", "ControlPath=\(app.sshControlPath(for: gateway))",
                    "-o", "BatchMode=yes"] + sshd.sshOptions
        args += ["-p", "\(sshd.port)", "-i", sshd.clientKey.path, "\(sshd.user)@\(sshd.hostName)"]
        let up = RemoteExec.shared.ssh(args: args, softTimeout: 10, captureStderr: true, label: "test")
        XCTAssertEqual(up.exit, 0, up.stderr + sshd.log)
    }

    func testACommandGoesThroughTheTunnelHost() {
        startGatewayMaster()
        let out = app.transport.runCommand("echo through-$((6*7))", on: inner, label: "t")
        XCTAssertEqual(out.exit, 0, out.stderr + sshd.log)
        XCTAssertTrue(out.stdout.contains("through-42"), out.stdout)
    }

    /// No master for the tunnel host: the attempt fails at once rather
    /// than opening a connection to the tunnel host of its own.
    func testNoTunnelHostMeansNoConnection() {
        let started = Date()
        let out = app.transport.runCommand("echo nope", on: inner, label: "t")
        XCTAssertEqual(out.exit, 255, out.stdout)
        XCTAssertFalse(out.stdout.contains("nope"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
