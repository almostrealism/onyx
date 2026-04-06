import XCTest
import Foundation
@testable import OnyxLib

/// Verifies that the option strings produced by AppState's SSH/SCP arg
/// builders are syntactically accepted by the real `ssh` binary on the host.
///
/// Strategy: invoke `ssh -G` with our arg list. `ssh -G` evaluates the
/// configuration and prints the resolved options without making a connection.
/// If we passed an unknown `-o key=value` pair, ssh prints
/// "Bad configuration option: <key>" on stderr and exits non-zero. That's the
/// regression we want to catch.
///
/// We can't pass `-i nonexistent` paths to `ssh -G` (it doesn't error on
/// those, but to be safe we leave identity files empty for the syntactic
/// check). We test the actual builders unmodified — only the `-i` arg is
/// optional in the test fixtures.
final class SSHArgsSyntaxTests: XCTestCase {

    private var sshURL: URL!
    private var appState: AppState!

    override func setUp() async throws {
        try await super.setUp()
        sshURL = try IntegrationTestHelpers.requireSSH()
        appState = await MainActor.run { AppState() }
    }

    override func tearDown() async throws {
        appState = nil
        try await super.tearDown()
    }

    private func makeHost(port: Int = 22) -> HostConfig {
        HostConfig(
            id: UUID(),
            label: "test-host",
            ssh: SSHConfig(host: "ssh-args-test.invalid", user: "tester", port: port)
        )
    }

    /// Run `ssh -G <args> <hostname>` and assert ssh did not reject any option.
    private func assertSSHAcceptsArgs(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        // ssh -G needs a hostname positional. We append a sentinel.
        let fullArgs: [String] = ["-G"] + args + ["ssh-args-test.invalid"]
        // -G doesn't accept -p; it parses Port from -o. Translate any "-p N"
        // pair to "-o Port=N" so the syntactic check still works for the
        // builder output that uses -p.
        var translated: [String] = []
        var i = 0
        while i < fullArgs.count {
            if fullArgs[i] == "-p", i + 1 < fullArgs.count {
                translated.append("-o")
                translated.append("Port=\(fullArgs[i + 1])")
                i += 2
            } else {
                translated.append(fullArgs[i])
                i += 1
            }
        }
        let result = IntegrationTestHelpers.runProcess(sshURL, arguments: translated, timeout: 5.0)
        XCTAssertFalse(
            result.stderr.contains("Bad configuration option"),
            "ssh rejected option syntax: \(result.stderr)\nargs: \(translated)",
            file: file, line: line
        )
        XCTAssertFalse(
            result.stderr.contains("unknown option"),
            "ssh reported unknown option: \(result.stderr)\nargs: \(translated)",
            file: file, line: line
        )
    }

    /// Run `scp <args>` with no source/dest in dry-eval mode. scp doesn't
    /// have a true dry-run, but it will validate `-o` keys before doing
    /// anything else and exit with usage error. We just check stderr for
    /// "Bad configuration option" / "unknown option".
    private func assertSCPAcceptsArgs(_ args: [String], file: StaticString = #filePath, line: UInt = #line) {
        let scpURL = URL(fileURLWithPath: "/usr/bin/scp")
        guard FileManager.default.isExecutableFile(atPath: scpURL.path) else {
            // Skip silently; scp is sometimes not present on minimal systems
            return
        }
        // Provide bogus src/dest so scp parses options and bails fast
        let fullArgs = args + ["/nonexistent/source", "user@ssh-args-test.invalid:/tmp/dest"]
        let result = IntegrationTestHelpers.runProcess(scpURL, arguments: fullArgs, timeout: 5.0)
        XCTAssertFalse(
            result.stderr.contains("Bad configuration option"),
            "scp rejected option syntax: \(result.stderr)\nargs: \(fullArgs)",
            file: file, line: line
        )
        XCTAssertFalse(
            result.stderr.contains("unknown option"),
            "scp reported unknown option: \(result.stderr)\nargs: \(fullArgs)",
            file: file, line: line
        )
    }

    func testSSHBaseArgsAreSyntacticallyValid() async {
        let host = makeHost()
        let args = await MainActor.run { appState.sshBaseArgs(for: host) }
        assertSSHAcceptsArgs(args)
    }

    func testSSHBaseArgsCustomPortAreSyntacticallyValid() async {
        let host = makeHost(port: 2222)
        let args = await MainActor.run { appState.sshBaseArgs(for: host) }
        assertSSHAcceptsArgs(args)
    }

    func testSSHBaseArgsBatchModeOff() async {
        let host = makeHost()
        let args = await MainActor.run { appState.sshBaseArgs(for: host, batchMode: false) }
        assertSSHAcceptsArgs(args)
    }

    func testSSHSessionArgsAreSyntacticallyValid() async {
        let host = makeHost()
        let args = await MainActor.run { appState.sshSessionArgs(for: host) }
        assertSSHAcceptsArgs(args)
    }

    func testSSHSessionArgsCustomPort() async {
        let host = makeHost(port: 2222)
        let args = await MainActor.run { appState.sshSessionArgs(for: host) }
        assertSSHAcceptsArgs(args)
    }

    func testSCPBaseArgsAreSyntacticallyValid() async {
        let host = makeHost()
        let args = await MainActor.run { appState.scpBaseArgs(for: host) }
        assertSCPAcceptsArgs(args)
    }
}
