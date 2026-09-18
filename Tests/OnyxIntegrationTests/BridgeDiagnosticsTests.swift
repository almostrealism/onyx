import XCTest
import Foundation
import Network

/// What an agent is told when Onyx can't be reached — and what it can
/// still do.
///
/// The complaint: agents were saying "onyx refused to connect" and nothing
/// else, because nothing else was available to say. A failed tool call
/// produced a one-word error, and if Onyx happened to be closed when the
/// session began, `initialize` failed and the client marked the server
/// dead for the whole session — Onyx opening a minute later changed
/// nothing. An agent in that position has to conclude "it's broken".
///
/// These drive the real binary, since every one of these behaviors is
/// about what crosses the stdio boundary.
final class BridgeDiagnosticsTests: XCTestCase {

    /// A desktop stand-in that says who it is.
    private final class FakeDesktop {
        private let listener: NWListener
        private var connections: [NWConnection] = []
        private(set) var port: UInt16 = 0

        init(machine: String) throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: .global())
                var buffer = Data()
                func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                        data, _, done, _ in
                        if let data { buffer.append(data) }
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[buffer.startIndex..<nl]
                            buffer.removeSubrange(buffer.startIndex...nl)
                            guard let object = try? JSONSerialization.jsonObject(with: Data(line))
                                    as? [String: Any],
                                  let id = object["id"] else { continue }
                            let method = object["method"] as? String ?? ""
                            let result: [String: Any]
                            switch method {
                            case "initialize":
                                result = ["protocolVersion": "2024-11-05",
                                          "capabilities": ["tools": [:]],
                                          "serverInfo": ["name": "onyx", "version": "0.17",
                                                         "machine": machine]]
                            case "tools/list":
                                result = ["tools": [["name": "notify", "description": "x",
                                                     "inputSchema": ["type": "object"]]]]
                            default:
                                result = ["content": [["type": "text", "text": "ok"]]]
                            }
                            let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
                            if let out = try? JSONSerialization.data(withJSONObject: reply) {
                                connection.send(content: out + Data("\n".utf8),
                                                completion: .contentProcessed { _ in })
                            }
                        }
                        if !done { receive() }
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

    private func sandbox() throws -> (env: [String: String], home: URL) {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".onyx"), withIntermediateDirectories: true)
        env["HOME"] = home.path
        env["ONYX_MCP_FORWARD_PORT"] = "0"
        env.removeValue(forKey: "ONYX_MCP_PORT")
        return (env, home)
    }

    private func responses(_ stdout: String) -> [[String: Any]] {
        stdout.components(separatedBy: "\n").compactMap {
            guard !$0.isEmpty, let data = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func toolNames(_ response: [String: Any]) -> [String] {
        ((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
    }

    // MARK: - The handshake never fails

    /// The fix for a session that begins while Onyx is closed.
    func testInitializeSucceedsWithNoDesktopAtAll() throws {
        let (env, _) = try sandbox()
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"# + "\n",
            environment: env, timeout: 20.0)

        let reply = try XCTUnwrap(responses(result.stdout).first)
        XCTAssertNotNil(reply["result"], "initialize must not fail: \(result.stdout)")
        let info = (reply["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertTrue((info?["note"] as? String)?.contains("onyx_status") == true,
                      "and it should say it's the bridge speaking, and what to call")
        let caps = (reply["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertEqual(((caps?["tools"] as? [String: Any])?["listChanged"]) as? Bool, true,
                       "so the client will accept a changed list later")
    }

    /// With no desktop, the tool list is the one tool the bridge serves
    /// itself — never empty, never an error.
    func testToolsListWithNoDesktopOffersStatus() throws {
        let (env, _) = try sandbox()
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n",
            environment: env, timeout: 20.0)
        let reply = try XCTUnwrap(responses(result.stdout).first)
        XCTAssertEqual(toolNames(reply), ["onyx_status"], result.stdout)
    }

    // MARK: - onyx_status

    func testStatusIsServedWithoutADesktop() throws {
        let (env, _) = try sandbox()
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"onyx_status","arguments":{}}}"#
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: call + "\n", environment: env, timeout: 20.0)
        let reply = try XCTUnwrap(responses(result.stdout).first)
        let text = (((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?
            .first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("none, ever"), "a fresh host has never reached Onyx: \(text)")
        XCTAssertTrue(text.contains("Routes to Onyx"), text)
        XCTAssertTrue(text.contains("Outbox"), text)
    }

    /// Once a desktop has answered, the list carries the real tools AND
    /// onyx_status, under the same name it had when the desktop was away.
    func testStatusIsAppendedToTheDesktopsOwnList() throws {
        let desktop = try FakeDesktop(machine: "mac-studio")
        defer { desktop.stop() }
        var (env, _) = try sandbox()
        env["ONYX_MCP_PORT"] = String(desktop.port)

        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n",
            environment: env, timeout: 20.0)
        let reply = try XCTUnwrap(responses(result.stdout).first)
        XCTAssertEqual(toolNames(reply), ["notify", "onyx_status"], result.stdout)
    }

    // MARK: - The error says something

    func testAFreshHostSaysOnyxHasNeverAnswered() throws {
        let (env, _) = try sandbox()
        let call = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"show_html","arguments":{}}}"#
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: call + "\n", environment: env, timeout: 20.0)
        let message = ((try XCTUnwrap(responses(result.stdout).first))["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("NEVER answered"), message)
        XCTAssertTrue(message.contains("install or connection problem"),
                      "name the class of problem, not just the symptom: \(message)")
        XCTAssertTrue(message.contains("--status"), "and say where to look: \(message)")
    }

    /// The ledger outlives the process, so a LATER session's error can
    /// name the desktop that used to answer.
    func testAfterADesktopHasAnsweredTheErrorNamesIt() throws {
        var (env, _) = try sandbox()
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()

        // Session one: the desktop is there.
        let desktop = try FakeDesktop(machine: "mac-studio")
        env["ONYX_MCP_PORT"] = String(desktop.port)
        _ = IntegrationTestHelpers.runProcess(
            binary, stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n",
            environment: env, timeout: 20.0)
        desktop.stop()

        // Session two: it isn't.
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_html","arguments":{}}}"#
        let result = IntegrationTestHelpers.runProcess(
            binary, stdin: call + "\n", environment: env, timeout: 25.0)
        let message = ((try XCTUnwrap(responses(result.stdout).first))["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("mac-studio"),
                      "the agent should be told WHO used to answer: \(message)")
        XCTAssertTrue(message.contains("last answered"), message)
        XCTAssertFalse(message.contains("NEVER"), "it has answered before; say so")
    }

    // MARK: - --status

    func testStatusCommandExitsOneWhenNothingIsReachable() throws {
        let (env, _) = try sandbox()
        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            arguments: ["--status"], stdin: "", environment: env, timeout: 20.0)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("Desktops that have answered"), result.stdout)
        XCTAssertTrue(result.stdout.contains("none, ever"), result.stdout)
    }

    func testStatusCommandListsADesktopItHasSeen() throws {
        var (env, _) = try sandbox()
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let desktop = try FakeDesktop(machine: "laptop")
        defer { desktop.stop() }
        env["ONYX_MCP_PORT"] = String(desktop.port)
        _ = IntegrationTestHelpers.runProcess(
            binary, stdin: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n",
            environment: env, timeout: 20.0)

        let result = IntegrationTestHelpers.runProcess(
            binary, arguments: ["--status"], stdin: "", environment: env, timeout: 20.0)
        XCTAssertEqual(result.exitCode, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("laptop"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Onyx 0.17"), result.stdout)
        XCTAssertTrue(result.stdout.contains("reachable now"), result.stdout)
    }
}
