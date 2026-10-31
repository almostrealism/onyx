import XCTest
import Foundation
import Network

/// The bridge writing, checking and reporting Claude Code's hooks.
///
/// Hooks are what list a host's Claude sessions in Onyx, and they used to
/// be broken in ways nothing reported: never written (a python3 merge that
/// said "hooks skipped" to nobody), written only for the account the
/// install ran as, or running and failing to reach Onyx without a trace.
/// The symptom of all three was the same — alerts from the host worked,
/// and its sessions never appeared.
final class BridgeHooksTests: XCTestCase {

    private func sandbox() throws -> (env: [String: String], home: URL) {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        env["HOME"] = home.path
        env["ONYX_MCP_FORWARD_PORT"] = "0"
        env.removeValue(forKey: "ONYX_MCP_PORT")
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        env.removeValue(forKey: "TMUX")
        return (env, home)
    }

    private func run(_ args: [String], env: [String: String], stdin: String? = nil)
        throws -> (out: String, code: Int32) {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let result = IntegrationTestHelpers.runProcess(binary, arguments: args, stdin: stdin,
                                                       environment: env, timeout: 10)
        XCTAssertFalse(result.timedOut, "\(args) hung; stderr=\(result.stderr)")
        return (result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), result.exitCode)
    }

    private func settings(_ home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let matchers = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return matchers.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
    }

    // MARK: - Writing

    func testInstallKeepsEverythingElseAndIsIdempotent() throws {
        let (env, home) = try sandbox()
        let existing = #"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"my-hook"}]}]}}"#
        try existing.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)

        let first = try run(["--install-hooks", "/opt/onyx/OnyxMCP"], env: env)
        XCTAssertEqual(first.code, 1, "the named binary doesn't exist, so the verdict is BROKEN")
        XCTAssertTrue(first.out.hasPrefix("HOOKS_BROKEN"), first.out)
        _ = try run(["--install-hooks", "/opt/onyx/OnyxMCP"], env: env)

        let s = try settings(home)
        XCTAssertEqual(s["model"] as? String, "opus", "other settings survive")
        // Every entry of ours carries a timeout: without one Claude waits
        // up to 60 seconds for a hook, on every tool call.
        let ours = ((s["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { ($0["command"] as? String ?? "").contains("OnyxMCP") }
        XCTAssertEqual(ours.first?["timeout"] as? Int, 5)
        let permission = ((s["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(permission.first?["timeout"] as? Int, 120, "a permission request waits on a person")
        XCTAssertEqual(commands(s, "PreToolUse"), ["my-hook", "/opt/onyx/OnyxMCP --hook PreToolUse"],
                       "the user's own hook survives, and ours appears once after two installs")
        for event in ["PostToolUse", "SessionStart", "SessionEnd", "Stop", "PermissionRequest"] {
            XCTAssertEqual(commands(s, event), ["/opt/onyx/OnyxMCP --hook \(event)"])
        }
    }

    func testInstallWithNoPathUsesThisBinaryAndReportsOK() throws {
        let (env, home) = try sandbox()
        let result = try run(["--install-hooks"], env: env)
        XCTAssertEqual(result.code, 0, result.out)
        XCTAssertTrue(result.out.hasPrefix("HOOKS_OK"), result.out)
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary().path
        XCTAssertTrue(commands(try settings(home), "Stop").first?.hasSuffix("OnyxMCP --hook Stop") ?? false)
        XCTAssertTrue(result.out.contains((binary as NSString).lastPathComponent))
    }

    /// The python3 merge replaced an unparsable file with `{}` — all of
    /// somebody's configuration, gone. The bridge refuses instead.
    func testASettingsFileThatIsntJSONIsLeftAlone() throws {
        let (env, home) = try sandbox()
        let path = home.appendingPathComponent(".claude/settings.json")
        try "{ // a comment\n \"model\": \"opus\" }".write(to: path, atomically: true, encoding: .utf8)
        let result = try run(["--install-hooks"], env: env)
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.out.hasPrefix("HOOKS_FAILED"), result.out)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "{ // a comment\n \"model\": \"opus\" }")
    }

    func testClaudeConfigDirIsRespected() throws {
        var (env, home) = try sandbox()
        let dir = home.appendingPathComponent("elsewhere")
        env["CLAUDE_CONFIG_DIR"] = dir.path
        XCTAssertEqual(try run(["--install-hooks"], env: env).code, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    // MARK: - Checking

    func testStatusVerdicts() throws {
        let (env, home) = try sandbox()
        let path = home.appendingPathComponent(".claude/settings.json")

        XCTAssertTrue(try run(["--hooks-status"], env: env).out.hasPrefix("HOOKS_MISSING"),
                      "no settings file means nothing configured")

        _ = try run(["--install-hooks"], env: env)
        let ok = try run(["--hooks-status"], env: env)
        XCTAssertEqual(ok.code, 0)
        XCTAssertTrue(ok.out.hasPrefix("HOOKS_OK"), ok.out)

        var s = try settings(home)
        s["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: s).write(to: path)
        XCTAssertTrue(try run(["--hooks-status"], env: env).out.hasPrefix("HOOKS_DISABLED"))

        s["disableAllHooks"] = nil
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        hooks["Stop"] = nil
        s["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: s).write(to: path)
        let partial = try run(["--hooks-status"], env: env).out
        XCTAssertTrue(partial.hasPrefix("HOOKS_PARTIAL") && partial.contains("Stop"), partial)
    }

    /// Hooks written before SessionEnd was one of ours are PARTIAL, which
    /// is what gets the host's hooks reinstalled. Without it a Claude that
    /// quits stays in the list.
    func testAnInstallFromBeforeSessionEndIsPartial() throws {
        let (env, home) = try sandbox()
        _ = try run(["--install-hooks"], env: env)
        let path = home.appendingPathComponent(".claude/settings.json")
        var s = try settings(home)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        hooks["SessionEnd"] = nil
        s["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: s).write(to: path)

        let partial = try run(["--hooks-status"], env: env).out
        XCTAssertEqual(partial.trimmingCharacters(in: .whitespacesAndNewlines),
                       "HOOKS_PARTIAL missing SessionEnd")
    }

    // MARK: - Running

    /// A hook that can't reach Onyx is still silent to Claude — it must
    /// never break a session — but it is written down, and `--status`
    /// says so.
    func testAFailedHookIsRecordedAndReported() throws {
        let (env, _) = try sandbox()
        _ = try run(["--install-hooks"], env: env)
        let hook = try run(["--hook", "PostToolUse"], env: env,
                           stdin: #"{"session_id":"s1","tool_name":"Bash"}"#)
        XCTAssertEqual(hook.code, 0)
        XCTAssertTrue(hook.out.isEmpty)

        let status = try run(["--status"], env: env).out
        XCTAssertTrue(status.contains("Claude Code hooks"), status)
        XCTAssertTrue(status.contains("configured for"), status)
        XCTAssertTrue(status.contains("last delivered: never"), status)
        XCTAssertTrue(status.contains("last failed: PostToolUse"), status)
    }

    /// One agent measured 31 seconds per hook — a minute per tool call —
    /// on a host where Onyx was unreachable. Against a route that accepts
    /// and never answers, a hook now gives up at its 3-second deadline,
    /// says which step it was stuck in, and the hooks after it don't try
    /// again for 30 seconds.
    func testAHookThatWouldHangGivesUpAndTheNextOnesDontTry() throws {
        var (env, _) = try sandbox()
        let silent = try SilentListener()
        defer { silent.stop() }
        env["ONYX_MCP_PORT"] = String(silent.port)
        env["ONYX_MCP_FORWARD_PORT"] = String(silent.port)
        let payload = #"{"session_id":"s1","tool_name":"Bash"}"#

        let start = Date()
        _ = try run(["--hook", "PostToolUse"], env: env, stdin: payload)
        let first = Date().timeIntervalSince(start)
        XCTAssertLessThan(first, 5, "the watchdog must end it — took \(first)s")

        // Read back without the silent routes: --status probes each route
        // for a person, at 5s apiece, and that isn't what's under test.
        var quiet = env
        quiet["ONYX_MCP_FORWARD_PORT"] = "0"
        quiet.removeValue(forKey: "ONYX_MCP_PORT")
        let status = try run(["--status"], env: quiet).out
        XCTAssertTrue(status.contains("gave up after 3s while waiting for"), status)

        let again = Date()
        _ = try run(["--hook", "PreToolUse"], env: env, stdin: payload)
        XCTAssertLessThan(Date().timeIntervalSince(again), 1,
                          "right after a hang, the next hook doesn't try at all")
    }

    /// A delivered hook carries where it came from, and the delivery is
    /// recorded with its route.
    func testADeliveredHookCarriesItsOriginAndIsRecorded() throws {
        var (env, _) = try sandbox()
        let desktop = try RecordingDesktop()
        defer { desktop.stop() }
        env["ONYX_MCP_PORT"] = String(desktop.port)
        env["USER"] = "agent"

        let hook = try run(["--hook", "PreToolUse"], env: env,
                           stdin: #"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        XCTAssertEqual(hook.code, 0)

        let event = try XCTUnwrap(desktop.hookParams.first, "the desktop never received the hook")
        XCTAssertEqual(event["hook_event_name"] as? String, "PreToolUse")
        let origin = try XCTUnwrap(event["onyx_origin"] as? [String: Any])
        XCTAssertEqual(origin["user"] as? String, "agent")
        XCTAssertFalse((origin["machine"] as? String ?? "").isEmpty)
        XCTAssertFalse((origin["machine"] as? String ?? "").contains("."),
                       "the machine is the short name, as the desktop shows it")

        let status = try run(["--status"], env: env).out
        XCTAssertTrue(status.contains("last delivered: PreToolUse"), status)
        XCTAssertTrue(status.contains("ONYX_MCP_PORT=\(desktop.port)"), status)
    }
}

/// A desktop stand-in that answers everything and keeps every hook it gets.
private final class RecordingDesktop {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var received: [[String: Any]] = []
    private(set) var port: UInt16 = 0

    var hookParams: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: .global())
            var buffer = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                    if let data { buffer.append(data) }
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                              let id = object["id"] else { continue }
                        if object["method"] as? String == "claude/hook",
                           let p = object["params"] as? [String: Any] {
                            self.lock.lock(); self.received.append(p); self.lock.unlock()
                        }
                        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["continue": true]]
                        if let out = try? JSONSerialization.data(withJSONObject: reply) {
                            connection.send(content: out + Data("\n".utf8), completion: .contentProcessed { _ in })
                        }
                    }
                    if !done { receive() }
                }
            }
            receive()
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw XCTSkip("couldn't bind a local listener")
        }
        port = bound
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

/// Accepts connections and never says a word — a stale `-R` forward, or a
/// wedged listener, from the bridge's point of view.
private final class SilentListener {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            self?.connections.append(connection)
            connection.start(queue: .global())
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            throw XCTSkip("couldn't bind a local listener")
        }
        port = bound
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}
