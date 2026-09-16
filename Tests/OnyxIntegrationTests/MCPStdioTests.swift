import XCTest
import Foundation
import Network
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
///   3. When no Onyx socket is reachable, sending a JSON-RPC line produces
///      a well-formed error frame on stdout (the bridge does NOT exit —
///      it keeps trying so subsequent requests can succeed when the
///      backend comes back)
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
        // And switch off the forwarded-port fallback. Otherwise these
        // tests pass or fail depending on whether Onyx happens to be
        // forwarding 19432 on the machine running them — which it is,
        // on any machine someone is actually using Onyx from.
        env["ONYX_MCP_FORWARD_PORT"] = "0"
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

    func testRequestWithNoSocketProducesJSONRPCErrorFrame() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        // Send one valid JSON-RPC request, then close stdin so the bridge
        // exits cleanly. With no backend socket the bridge retries and then
        // emits a per-request error frame — but importantly does NOT exit
        // until stdin is closed.
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n"
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: [],
            stdin: request,
            environment: sandboxEnvironment(),
            timeout: 8.0  // 3 retries with backoff can take a few seconds
        )
        XCTAssertFalse(result.timedOut, "OnyxMCP hung instead of returning error frame")
        // Exit code on stdin close: process exits normally (0 or 1 either is OK).
        XCTAssertTrue(result.stdout.contains("\"jsonrpc\""), "Missing jsonrpc field. stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("\"error\""), "Missing error field. stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("-32000"), "Expected error code -32000. stdout=\(result.stdout)")
        // The error should reference the new behavior (retries / unreachable)
        XCTAssertTrue(result.stdout.contains("unreachable") || result.stdout.contains("retr"),
                      "Error message should mention retries or unreachable backend. stdout=\(result.stdout)")
    }

    func testStderrMentionsRetries() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n"
        let result = IntegrationTestHelpers.runProcess(
            binary,
            stdin: request,
            environment: sandboxEnvironment(),
            timeout: 8.0
        )
        // Bridge logs retry attempts on stderr; verify any OnyxMCP: line appears
        XCTAssertTrue(
            result.stderr.contains("OnyxMCP:"),
            "Expected OnyxMCP diagnostic on stderr; got: \(result.stderr)"
        )
    }

    func testBridgeStaysAliveAfterFailedRequest() throws {
        // Send TWO requests through the bridge with no backend. Both should
        // produce error frames (the bridge does NOT exit after the first
        // failure — it keeps reading stdin so a transient backend outage
        // doesn't tear down the Claude session).
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list"}

        """
        let result = IntegrationTestHelpers.runProcess(
            binary,
            arguments: [],
            stdin: requests,
            environment: sandboxEnvironment(),
            timeout: 15.0
        )
        XCTAssertFalse(result.timedOut)
        // Should see TWO JSON-RPC error frames (one per request)
        let lines = result.stdout.split(separator: "\n").filter { $0.contains("\"jsonrpc\"") }
        XCTAssertEqual(lines.count, 2,
                       "Expected 2 error frames (bridge must survive first failure). stdout=\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("\"id\":1"))
        XCTAssertTrue(result.stdout.contains("\"id\":2"))
    }
}

/// A port that is NOT Onyx.
///
/// The failure this reproduces, from a user's tailnet host: Claude hung for
/// 30 seconds and then said "MCP server onyx connection timed out". The
/// forwarded port is a well-known number on a machine we don't own — a
/// stale `ssh -R` whose far end died with the app that made it, another
/// user's forward, or any unrelated service — and all of those ACCEPT the
/// connection and then say nothing. The bridge used to connect, trust it,
/// and wait out its full 30-second receive timeout, which is exactly
/// Claude's startup budget.
final class MCPRouteSelectionTests: XCTestCase {

    /// Accepts connections. Optionally answers; by default, silence.
    private final class FakePeer {
        private let listener: NWListener
        private var connections: [NWConnection] = []
        private(set) var port: UInt16 = 0

        init(answering: Bool) throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: .global())
                guard answering else { return }   // silence is the point of the other mode
                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                        data, _, _, _ in
                        if let data, !data.isEmpty,
                           let text = String(data: data, encoding: .utf8),
                           text.contains("\"id\"") {
                            let reply = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"# + "\n"
                            connection.send(content: Data(reply.utf8),
                                            completion: .contentProcessed { _ in })
                        }
                        receive()
                    }
                }
                receive()
            }
            listener.start(queue: .global())
            guard ready.wait(timeout: .now() + 5) == .success,
                  let bound = listener.port?.rawValue else {
                throw XCTSkip("couldn't bind a local listener")
            }
            port = bound
        }

        func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
    }

    private func environment(envPort: UInt16?, forwardPort: UInt16) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-route-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        env["HOME"] = temp.path          // no real ~/.onyx/mcp.sock in reach
        env["ONYX_MCP_FORWARD_PORT"] = String(forwardPort)
        if let envPort { env["ONYX_MCP_PORT"] = String(envPort) } else {
            env.removeValue(forKey: "ONYX_MCP_PORT")
        }
        return env
    }

    /// The bug: silence must not cost Claude its whole startup budget.
    func testASilentPortDoesNotHangTheBridge() throws {
        let squatter = try FakePeer(answering: false)
        defer { squatter.stop() }

        let started = Date()
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n",
            environment: environment(envPort: nil, forwardPort: squatter.port),
            timeout: 28.0)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(result.timedOut, "the bridge hung on a port that never answers")
        XCTAssertLessThan(elapsed, 25,
                          "took \(Int(elapsed))s — Claude gives an MCP server 30s, and a "
                          + "bridge that spends it all reports nothing at all")
        XCTAssertTrue(result.stdout.contains("\"error\""),
                      "an unreachable backend should still answer: \(result.stdout)")
        XCTAssertTrue(result.stderr.contains("not Onyx"),
                      "and should say WHICH route was wrong: \(result.stderr)")
    }

    /// Having rejected the impostor, it must go on and find the real one.
    func testItRotatesPastASilentPortToAWorkingOne() throws {
        let squatter = try FakePeer(answering: false)
        let real = try FakePeer(answering: true)
        defer { squatter.stop(); real.stop() }

        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n",
            // The squatter is FIRST in the route order.
            environment: environment(envPort: squatter.port, forwardPort: real.port),
            timeout: 28.0)

        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.contains("\"ok\""),
                      "should have reached the answering peer: \(result.stdout)")
        XCTAssertTrue(result.stderr.contains("connected to Onyx via"),
                      "and should say which route worked: \(result.stderr)")
    }

    /// `--probe` exists so an install can answer "can this host reach
    /// Onyx" on the spot, instead of the first symptom being a 30-second
    /// hang that names no cause.
    func testProbeReportsASilentPortRatherThanClaimingSuccess() throws {
        let squatter = try FakePeer(answering: false)
        defer { squatter.stop() }

        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            arguments: ["--probe"],
            stdin: "",
            environment: environment(envPort: nil, forwardPort: squatter.port),
            timeout: 20.0)

        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stdout.contains("NOT REACHABLE"), result.stdout)
        XCTAssertTrue(result.stdout.contains("silence"),
                      "name the symptom so a user can act on it: \(result.stdout)")
    }
}
