import XCTest
import Foundation
@testable import OnyxLib

/// Regression tests for SSH ControlMaster path handling and stale-mux cleanup.
///
/// See: ADR-005 (SSH ControlMaster paths).
///
/// These tests reach into the argument list produced by `sshBaseArgs` to
/// locate the `ControlPath=...` value and verify:
///   1. The path never contains whitespace (past bug: ~/Library/Application
///      Support/ broke ssh arg parsing).
///   2. `markMuxStale(for:)` followed by `sshBaseArgs(for:)` removes any
///      existing socket file at that path.
///   3. The stale flag is per-host — flagging host A does not clean up B.
final class SSHMuxTests: XCTestCase {

    private func extractControlPath(from args: [String]) -> String? {
        for (i, a) in args.enumerated() where a.hasPrefix("ControlPath=") {
            return String(a.dropFirst("ControlPath=".count))
        }
        // Some args are passed as ["-o", "ControlPath=..."] — the above loop
        // already handles that because we scan every element.
        _ = args
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

    // MARK: - markMuxStale behavior

    /// Regression: after a broken pipe, `markMuxStale(hostID)` plus the next
    /// `sshBaseArgs(for:)` call must delete any leftover socket file.
    /// Failing to do so caused new ssh commands to hang forever on the
    /// dead master connection.
    func testMarkMuxStale_removesSocketFileOnNextBaseArgs() throws {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let path = try XCTUnwrap(extractControlPath(from: state.sshBaseArgs(for: host)))

        // Create a placeholder file at the mux path
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data("fake socket".utf8))
        XCTAssertTrue(fm.fileExists(atPath: path), "Fixture file should exist")

        // Mark stale then fetch base args — the flagged host's socket should be gone
        state.markMuxStale(for: host.id)
        _ = state.sshBaseArgs(for: host)

        XCTAssertFalse(fm.fileExists(atPath: path),
                       "sshBaseArgs must delete a stale mux socket after markMuxStale")
    }

    /// markMuxStale on host A must not affect host B's socket. Earlier a
    /// global flag was considered — this test guards against reintroducing
    /// cross-host cleanup.
    func testMarkMuxStale_isPerHost() throws {
        let state = AppState()
        let hostA = makeHost(label: "alpha")
        let hostB = makeHost(label: "beta")
        let pathA = try XCTUnwrap(extractControlPath(from: state.sshBaseArgs(for: hostA)))
        let pathB = try XCTUnwrap(extractControlPath(from: state.sshBaseArgs(for: hostB)))

        let fm = FileManager.default
        try fm.createDirectory(atPath: (pathA as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        fm.createFile(atPath: pathA, contents: Data("A".utf8))
        fm.createFile(atPath: pathB, contents: Data("B".utf8))

        state.markMuxStale(for: hostA.id)
        _ = state.sshBaseArgs(for: hostA)
        _ = state.sshBaseArgs(for: hostB)

        XCTAssertFalse(fm.fileExists(atPath: pathA), "Host A socket should be cleaned")
        XCTAssertTrue(fm.fileExists(atPath: pathB), "Host B socket must be untouched")

        // Cleanup
        try? fm.removeItem(atPath: pathB)
    }

    /// The stale flag is consumed — calling sshBaseArgs twice must only
    /// clean up once. (Otherwise a reconnect loop could re-delete a live
    /// socket on every retry.)
    func testMarkMuxStale_consumedAfterFirstUse() throws {
        let state = AppState()
        let host = makeHost(label: "alpha")
        let path = try XCTUnwrap(extractControlPath(from: state.sshBaseArgs(for: host)))
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)

        state.markMuxStale(for: host.id)
        _ = state.sshBaseArgs(for: host)  // consumes flag

        // Now create a new socket file and call sshBaseArgs again — the flag
        // was already consumed, so the new file must survive.
        fm.createFile(atPath: path, contents: Data("fresh".utf8))
        _ = state.sshBaseArgs(for: host)
        XCTAssertTrue(fm.fileExists(atPath: path),
                      "Stale flag must be consumed after first use, not re-applied")
        try? fm.removeItem(atPath: path)
    }
}
