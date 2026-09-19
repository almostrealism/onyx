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

/// The bridge survives the desktop hanging up on it.
///
/// From an agent's report: "First notify call returned Connection closed.
/// An immediate identical retry succeeded. Right after that the whole
/// server disconnected and never came back." That is a process DYING. A
/// write to a socket the far end has RESET raises SIGPIPE, whose default
/// action terminates the process — and the far end resets whenever the
/// connection pair tears down its `-R` forward, and whenever the desktop
/// cancels a connection. Claude restarts the server after the first death
/// (hence the retry working), and gives up after a few.
///
/// The peer here answers one request and then closes with SO_LINGER=0,
/// which sends RST rather than FIN. A FIN lets one more write through
/// before EPIPE; an RST does not, and it is the RST that kills. This test
/// FAILS against a bridge without `signal(SIGPIPE, SIG_IGN)`.
final class BridgeSurvivesHangupTests: XCTestCase {

    /// A POSIX listener: answers one line per connection, then resets.
    private final class ResettingPeer {
        private let fd: Int32
        private(set) var port: UInt16 = 0
        private(set) var accepted = 0
        private var running = true
        private let lock = NSLock()

        init() throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else { throw XCTSkip("couldn't listen") }
            var bound_addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound_addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            port = UInt16(bigEndian: bound_addr.sin_port)

            Thread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    lock.lock(); let go = running; lock.unlock()
                    guard go, client >= 0 else { break }
                    lock.lock(); accepted += 1; lock.unlock()
                    // One line in.
                    var line: [UInt8] = []
                    var byte: UInt8 = 0
                    while read(client, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                    if let text = String(bytes: line, encoding: .utf8),
                       let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = object["id"],
                       let out = try? JSONSerialization.data(withJSONObject:
                            ["jsonrpc": "2.0", "id": id, "result": ["served": true]] as [String: Any]) {
                        var bytes = [UInt8](out); bytes.append(0x0A)
                        _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                    }
                    // RST, not FIN.
                    var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
                    setsockopt(client, SOL_SOCKET, SO_LINGER, &linger,
                               socklen_t(MemoryLayout<Darwin.linger>.size))
                    close(client)
                }
            }.start()
        }

        func stop() {
            lock.lock(); running = false; lock.unlock()
            close(fd)
        }
    }

    func testAPeerThatResetsDoesNotKillTheBridge() throws {
        let peer = try ResettingPeer()
        defer { peer.stop() }
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-hangup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".onyx"), withIntermediateDirectories: true)
        env["HOME"] = home.path
        env["ONYX_MCP_PORT"] = String(peer.port)
        env["ONYX_MCP_FORWARD_PORT"] = "0"

        // Three calls. Every connection is reset after one answer, so the
        // bridge's own identify request (sent right after the first answer)
        // and each later call all write into a reset socket first.
        let calls = (1...3).map {
            #"{"jsonrpc":"2.0","id":\#($0),"method":"tools/call","params":{"name":"notify","arguments":{"title":"n\#($0)"}}}"#
        }.joined(separator: "\n") + "\n"

        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: calls, environment: env, timeout: 40.0)

        XCTAssertFalse(result.timedOut)
        let frames = result.stdout.split(separator: "\n").filter { $0.contains("\"jsonrpc\"") }
        XCTAssertEqual(frames.count, 3,
                       "every call must be answered; a process killed by SIGPIPE answers "
                       + "none after the reset. exit=\(result.exitCode) stdout=\(result.stdout) "
                       + "stderr=\(result.stderr)")
        XCTAssertTrue(frames.allSatisfy { $0.contains("\"served\"") },
                      "answered by the PEER via reconnects, not by error frames: \(result.stdout)")
        XCTAssertGreaterThanOrEqual(peer.accepted, 3, "one reconnect per reset")
    }

    /// `ping` is the client asking whether the server is alive. It is —
    /// whatever the desktop is doing.
    func testPingIsAnsweredWithNoDesktop() throws {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-ping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".onyx"), withIntermediateDirectories: true)
        env["HOME"] = home.path
        env["ONYX_MCP_FORWARD_PORT"] = "0"
        env.removeValue(forKey: "ONYX_MCP_PORT")

        let result = IntegrationTestHelpers.runProcess(
            try IntegrationTestHelpers.requireOnyxMCPBinary(),
            stdin: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"# + "\n",
            environment: env, timeout: 15.0)
        XCTAssertTrue(result.stdout.contains(#""id":7"#), result.stdout)
        XCTAssertTrue(result.stdout.contains(#""result":{}"#),
                      "an empty result, immediately — not an error, not a wait: \(result.stdout)")
    }
}
