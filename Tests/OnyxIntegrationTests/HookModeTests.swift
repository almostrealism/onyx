import XCTest
import Foundation
@testable import OnyxLib

/// Tests for `OnyxMCP --hook` invocation.
///
/// Per `Sources/OnyxMCP/main.swift`, hook mode:
///   - Reads a complete JSON object from stdin
///   - Wraps it in a JSON-RPC `claude/hook` call
///   - Sends it to the running Onyx app over the Unix socket
///   - On the no-socket / no-response paths, exits 0 silently so Claude
///     Code falls through to its default behavior
///
/// This means: with no Onyx app running we cannot exercise the happy path,
/// only the silent-fallback path. We verify that path is robust:
///   * Valid JSON payloads → exit 0, no stdout
///   * Empty stdin → exit 0
///   * Malformed JSON → does not hang (the loop reads availableData and tries
///     to parse; with EOF on stdin and unparseable bytes, it must terminate)
///
/// FINDING: The current main.swift implementation relies on Claude Code being
/// alive on the other end of the Unix socket to validate hook payloads. There
/// is no local schema validation, so a malformed payload behaves identically
/// to a valid one when no socket is reachable. That makes "malformed payload
/// → non-zero exit with diagnostic" untestable without the GUI app. Logged
/// here as a potential follow-up: hook mode could do a quick local
/// JSONSerialization check and emit a diagnostic on stderr before bridging.
final class HookModeTests: XCTestCase {

    private func sandboxEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-hook-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        env["HOME"] = temp.path
        env.removeValue(forKey: "ONYX_MCP_PORT")
        return env
    }

    func testHookModeWithPreToolUsePayloadExitsCleanly() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let payload = #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: ["--hook"],
            stdin: payload,
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut, "hook mode hung; stderr=\(result.stderr)")
        XCTAssertEqual(result.exitCode, 0, "hook mode should exit 0 on no-socket fallback; stderr=\(result.stderr)")
        // No-socket path: nothing is written to stdout (Claude continues normally).
        XCTAssertTrue(result.stdout.isEmpty, "expected empty stdout, got: \(result.stdout)")
    }

    func testHookModeWithPostToolUsePayloadExitsCleanly() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let payload = #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"output":"file1\nfile2"}}"#
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: ["--hook"],
            stdin: payload,
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHookModeWithSessionStartPayloadExitsCleanly() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let payload = #"{"hook_event_name":"SessionStart","session_id":"test-session"}"#
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: ["--hook"],
            stdin: payload,
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHookModeWithEmptyStdinExitsCleanly() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: ["--hook"],
            stdin: "",
            environment: sandboxEnvironment(),
            timeout: 3.0
        )
        XCTAssertFalse(result.timedOut, "hook mode hung on empty stdin")
        XCTAssertEqual(result.exitCode, 0)
    }
}
