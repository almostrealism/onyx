import XCTest
@testable import OnyxCore
@testable import OnyxLib
@testable import OnyxSSH

/// The built-in client on a Mac connects where OpenSSH would, as whom it
/// would, with the keys it would — by asking `ssh -G`.
final class OpenSSHConfigResolverTests: XCTestCase {

    func testArgumentsMatchEveryOtherSSHCommand() {
        let plain = HostConfig(label: "a", ssh: SSHConfig(host: "box"))
        XCTAssertEqual(OpenSSHConfigResolver.arguments(for: plain), ["-G", "box"])
        let full = HostConfig(label: "b", ssh: SSHConfig(host: "box", user: "me", port: 2222, identityFile: "~/.ssh/k"))
        XCTAssertEqual(OpenSSHConfigResolver.arguments(for: full), ["-G", "-p", "2222", "-i", "~/.ssh/k", "me@box"])
    }

    func testOutputIsRead() throws {
        let resolved = try OpenSSHConfigResolver.parse("""
        user deploy
        hostname 10.0.0.5
        port 2200
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/work
        proxyjump none

        """)
        XCTAssertEqual(resolved, ResolvedHost(hostName: "10.0.0.5", port: 2200, user: "deploy",
                                              identityFiles: ["~/.ssh/id_ed25519", "~/.ssh/work"]))
    }

    /// Connecting straight to a host that is only reachable through a jump
    /// host would reach the wrong machine, or none; say so instead.
    func testAJumpHostIsRefusedNotIgnored() {
        XCTAssertThrowsError(try OpenSSHConfigResolver.parse("hostname inner\nuser me\nproxyjump bastion\n")) { error in
            XCTAssertTrue("\(error)".contains("ProxyJump"), "\(error)")
        }
        XCTAssertThrowsError(try OpenSSHConfigResolver.parse("hostname inner\nuser me\nproxycommand nc %h %p\n"))
    }

    func testTheRealSSHAgrees() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else { throw XCTSkip("no ssh") }
        let host = HostConfig(label: "x", ssh: SSHConfig(host: "onyx-resolver-test.invalid", user: "someone", port: 2345))
        let resolved = try OpenSSHConfigResolver.shared.resolve(host)
        XCTAssertEqual(resolved.user, "someone")
        XCTAssertEqual(resolved.port, 2345)
        XCTAssertFalse(resolved.identityFiles.isEmpty, "OpenSSH always names its default keys")
    }
}
