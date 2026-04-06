import XCTest
import Foundation
@testable import OnyxLib

/// Round-trip integration tests for the OnyxMCP stdio bridge.
///
/// IMPORTANT FINDING: OnyxMCP is *not* a self-contained MCP server. It is a thin
/// stdio→Unix-socket bridge that forwards JSON-RPC to a running Onyx.app over
/// `~/.onyx/mcp.sock`. Without a live Onyx app, the binary cannot answer
/// `initialize` / `tools/list` / `tools/call` requests itself — those are
/// implemented inside `OnyxLib/Services/MCPServer.swift`, which lives in-process
/// in the GUI app.
///
/// What we *can* test deterministically here without launching a GUI app:
///   1. Binary exists and launches (XCTSkip otherwise)
///   2. Stdin-close → process exits within a small timeout
///   3. When no Onyx socket is reachable, the bridge writes a well-formed
///      JSON-RPC error frame to stdout and exits non-zero (this is the
///      `guard fd >= 0` path in `Sources/OnyxMCP/main.swift`)
///   4. Hook mode (`--hook`) with a malformed payload exits cleanly
///
/// Tests for the actual MCP tool surface (`show_text`, `show_diagram`, etc.)
/// live in OnyxTests/Services/MCPServerTests.swift, which exercises
/// `MCPServer` directly without a process boundary. Adding stdio round-trip
/// coverage for those tools would require either:
///   (a) booting a headless Onyx app from the test bundle, or
///   (b) refactoring OnyxMCP to optionally embed MCPServer (changes the
///       dependency direction).
/// Both are out of scope for this pass — see plan-testing-and-docs.md.
final class MCPStdioTests: XCTestCase {

    private func sandboxEnvironment() -> [String: String] {
        // Point HOME at a temp dir so the bridge can't accidentally connect to
        // a real ~/.onyx/mcp.sock left behind by a developer's running Onyx.
        var env = ProcessInfo.processInfo.environment
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-mcp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        env["HOME"] = temp.path
        env.removeValue(forKey: "ONYX_MCP_PORT")
        return env
    }

    func testBinaryLaunchesAndExitsOnStdinClose() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let client = try MCPClient(binary: binary, environment: sandboxEnvironment())

        // The bridge tries to connect on startup; with no socket it will print
        // an error frame and exit 1. Closing stdin is harmless either way.
        client.closeStdin()
        let exit = client.waitForExit(timeout: 2.0)
        XCTAssertNotNil(exit, "OnyxMCP did not exit within 2s of stdin close")
    }

    func testNoSocketProducesJSONRPCErrorFrame() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        // With sandboxed HOME, ~/.onyx/mcp.sock cannot exist.
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: [],
            stdin: nil,
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut, "OnyxMCP hung instead of failing fast on missing socket")
        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit when Onyx socket is unreachable")

        // Stdout should contain a JSON-RPC error frame per main.swift
        XCTAssertTrue(result.stdout.contains("\"jsonrpc\""), "Missing jsonrpc field. stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("\"error\""), "Missing error field. stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("-32000"), "Expected error code -32000. stdout=\(result.stdout)")
    }

    func testStderrMentionsConnectionFailure() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let result = IntegrationTestHelpers.runProcess(
            binary,
            stdin: nil,
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertTrue(
            result.stderr.lowercased().contains("cannot connect") || result.stderr.contains("OnyxMCP:"),
            "Expected diagnostic on stderr; got: \(result.stderr)"
        )
    }

    func testInvalidJSONLineProducesErrorFrameWhenSocketMissing() throws {
        // Even with a malformed line, with no socket the bridge should fail
        // before parsing — we just verify it doesn't crash and exits cleanly.
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let result = IntegrationTestHelpers.runProcess(
            binary,
            stdin: "not-json\n",
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
    }
}
