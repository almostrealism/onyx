import XCTest
import Foundation
@testable import OnyxCore
@testable import OnyxLib

/// Regression tests for SSH ControlMaster path handling and the
/// utility-traffic mux-client discipline.
///
/// See: ADR-005 (SSH ControlMaster paths).
///
/// These tests reach into the argument list produced by `sshBaseArgs` to
/// locate the `ControlPath=...` value and verify:
///   1. The path never contains whitespace (past bug: ~/Library/Application
///      Support/ broke ssh arg parsing).
///   2. Utility commands are mux CLIENTS only (`ControlMaster=no`) — they
///      can never spawn their own master/TCP connection. The pair
///      supervisor owns the only two connections to a host.
final class SSHMuxTests: XCTestCase {

    private func extractControlPath(from args: [String]) -> String? {
        for a in args where a.hasPrefix("ControlPath=") {
            return String(a.dropFirst("ControlPath=".count))
        }
        return nil
    }

    private func makeHost(label: String) -> HostConfig {
        HostConfig(id: UUID(), label: label, ssh: SSHConfig(host: "example.com", user: "root"))
    }

    // MARK: - Control path shape

    /// Regression (ADR-005): mux path must be free of whitespace. We moved
    /// the mux dir out of ~/Library/Application Support/ precisely because
    /// spaces in the path broke ssh's argument parsing in some shells.
    func testControlPath_containsNoWhitespace() {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let args = state.sshBaseArgs(for: host)
        let path = extractControlPath(from: args)
        XCTAssertNotNil(path, "sshBaseArgs must include a ControlPath option")
        XCTAssertFalse(path!.contains(" "),
                       "ControlPath must not contain spaces (breaks ssh arg parsing): \(path!)")
        XCTAssertFalse(path!.contains("\t"),
                       "ControlPath must not contain tabs: \(path!)")
    }

    /// Each host gets its own socket path (keyed by UUID) so multiplexing
    /// stays isolated per host.
    func testControlPath_isUniquePerHost() {
        let state = AppState()
        let hostA = makeHost(label: "alpha")
        let hostB = makeHost(label: "beta")
        let pathA = extractControlPath(from: state.sshBaseArgs(for: hostA))
        let pathB = extractControlPath(from: state.sshBaseArgs(for: hostB))
        XCTAssertNotNil(pathA)
        XCTAssertNotNil(pathB)
        XCTAssertNotEqual(pathA, pathB, "Each host must get its own ControlPath")
    }

    func testControlPath_stableAcrossCalls() {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let p1 = extractControlPath(from: state.sshBaseArgs(for: host))
        let p2 = extractControlPath(from: state.sshBaseArgs(for: host))
        XCTAssertEqual(p1, p2, "Same host must return the same ControlPath across calls")
    }

    // MARK: - Mux-client discipline (the two-connection cap)

    /// THE cap regression test: utility ssh commands must be mux clients
    /// (`ControlMaster=no`), never `auto` — `auto` let every utility call
    /// spawn its own master when the pair was down, blowing the
    /// two-connections-per-host cap on flaky networks.
    func testSshBaseArgs_isMuxClientOnly() {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let args = state.sshBaseArgs(for: host)
        XCTAssertTrue(args.contains("ControlMaster=no"),
                      "utility ssh must never spawn its own ControlMaster")
        XCTAssertFalse(args.contains("ControlMaster=auto"),
                       "ControlMaster=auto violates the two-connection cap")
    }

    func testScpBaseArgs_isMuxClientOnly() {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let args = state.scpBaseArgs(for: host)
        XCTAssertTrue(args.contains("ControlMaster=no"),
                      "scp must never spawn its own ControlMaster")
        XCTAssertFalse(args.contains("ControlMaster=auto"))
    }

    /// The ControlPath handed to utility commands must be one of the
    /// pair's slot paths — utility traffic rides the pair, nothing else.
    func testSshBaseArgs_controlPathIsAPairSlotPath() throws {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let path = try XCTUnwrap(extractControlPath(from: state.sshBaseArgs(for: host)))
        let slot0 = ConnectionPair.slotPath(for: host.id, slot: 0)
        let slot1 = ConnectionPair.slotPath(for: host.id, slot: 1)
        XCTAssertTrue(path == slot0 || path == slot1,
                      "utility ControlPath must be a pair slot path, got: \(path)")
    }
}

/// A host reached through another: every builder carries the tunnel, after
/// the host's own ControlPath, and the tunnel rides the tunnel host's pair.
final class SSHTunnelArgsTests: XCTestCase {

    private func hosts() -> (AppState, HostConfig, HostConfig) {
        let state = AppState()
        let gateway = HostConfig(label: "gateway",
                                 ssh: SSHConfig(host: "gw.example", user: "ops", port: 2222,
                                                identityFile: "~/keys/it's 100%"))
        let inner = HostConfig(label: "inner", ssh: SSHConfig(host: "10.0.0.5", user: "root"),
                               tunnelHostID: gateway.id)
        state.hosts = [.localhost, gateway, inner]
        return (state, gateway, inner)
    }

    private func proxyCommand(in args: [String]) -> String? {
        args.first { $0.hasPrefix("ProxyCommand=") }.map { String($0.dropFirst("ProxyCommand=".count)) }
    }

    func testADirectHostHasNoTunnel() {
        let (state, gateway, _) = hosts()
        XCTAssertNil(proxyCommand(in: state.sshBaseArgs(for: gateway)))
        XCTAssertNil(proxyCommand(in: state.sshSessionArgs(for: gateway)))
    }

    func testEveryBuilderCarriesTheTunnel() {
        let (state, _, inner) = hosts()
        for args in [state.sshBaseArgs(for: inner), state.sshSessionArgs(for: inner),
                     state.scpBaseArgs(for: inner),
                     state.scpCommand(localPath: "/tmp/a", remotePath: "a", host: inner).args] {
            XCTAssertNotNil(proxyCommand(in: args), "\(args)")
            // The orphan reaper reads the FIRST ControlPath= as the
            // process's own; the tunnel's comes later, inside the command.
            let own = args.firstIndex { $0.hasPrefix("ControlPath=") }
            let tunnel = args.firstIndex { $0.hasPrefix("ProxyCommand=") }
            XCTAssertLessThan(own ?? .max, tunnel ?? .min)
        }
    }

    /// Through the tunnel host's own master, never a connection of its own.
    func testTheTunnelRidesTheTunnelHostsPair() {
        let (state, gateway, inner) = hosts()
        let command = proxyCommand(in: state.sshBaseArgs(for: inner))!
        XCTAssertTrue(command.contains("'ControlMaster=no'"))
        XCTAssertTrue(command.contains("'ControlPath=\(state.sshControlPath(for: gateway))'"))
        XCTAssertTrue(command.contains("'ProxyCommand=/usr/bin/false'"),
                      "a dead socket must fail, not open a third connection to the tunnel host")
        XCTAssertTrue(command.contains("'-p' '2222'"))
        XCTAssertTrue(command.contains("'ops@gw.example'"))
        XCTAssertTrue(command.hasSuffix(" -W %h:%p"))
    }

    /// ssh expands % and runs the command in /bin/sh.
    func testTheTunnelSurvivesQuotesAndPercents() {
        let (state, _, inner) = hosts()
        let command = proxyCommand(in: state.sshBaseArgs(for: inner))!
        XCTAssertTrue(command.contains(#"'~/keys/it'\''s 100%%'"#), command)
    }

    func testATunneledHostWaitsForItsTunnelHost() {
        let (state, gateway, inner) = hosts()
        // No pair has come up in a test.
        XCTAssertFalse(state.tunnelReady(for: inner))
        XCTAssertTrue(state.tunnelReady(for: gateway))
        var orphan = inner
        orphan.tunnelHostID = UUID()
        XCTAssertFalse(state.tunnelReady(for: orphan), "never direct when the tunnel host is gone")
    }
}
