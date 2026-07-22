import XCTest
import Foundation
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
