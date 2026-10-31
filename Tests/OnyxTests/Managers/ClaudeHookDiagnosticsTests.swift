import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Why a host's Claude sessions can be missing while its alerts work, and
/// the tools that now say which reason it is.
///
/// The sessions list is fed by Claude Code HOOKS — separate processes,
/// configured per account — not by the MCP connection alerts use. Hooks
/// could be unwritten, written for a different account, or failing to
/// reach Onyx, and none of the three was visible anywhere.
final class ClaudeHookDiagnosticsTests: XCTestCase {

    // MARK: - The status check's verdicts

    func testHookVerdictsBecomeSentences() {
        XCTAssertNil(MCPInstaller.hooksProblem(in: "HOOKS_OK /home/me/.onyx/bin/OnyxMCP"))
        XCTAssertNil(MCPInstaller.hooksProblem(in: "HOOKS_UNKNOWN bridge too old to say"),
                     "an old bridge is reported as outdated, not as broken hooks")
        XCTAssertNil(MCPInstaller.hooksProblem(in: nil))
        XCTAssertEqual(MCPInstaller.hooksProblem(in: "HOOKS_MISSING none configured"),
                       "Claude Code hooks aren't configured, so this host's sessions won't be listed")
        XCTAssertTrue(MCPInstaller.hooksProblem(in: "HOOKS_PARTIAL missing Stop")?.contains("Stop") ?? false)
        XCTAssertTrue(MCPInstaller.hooksProblem(in: "HOOKS_DISABLED x")?.contains("disableAllHooks") ?? false)
        XCTAssertEqual(MCPInstaller.hooksProblem(in: "HOOKS_FAILED settings.json isn't valid JSON"),
                       "settings.json isn't valid JSON")
        XCTAssertEqual(MCPInstaller.hooksProblem(in: "zsh: permission denied: OnyxMCP"),
                       "zsh: permission denied: OnyxMCP", "anything else is the remote's own words")
    }

    func testTheStatusCheckCarriesTheHooksProblem() {
        let output = """
        ---UNAME---
        Linux
        aarch64
        ---BASE---
        /home/me
        ---BIN---
        OnyxMCP 0.19 (proto 4)
        ---REG---
        REGISTERED
        ---HOOKS---
        HOOKS_MISSING none configured
        """
        let status = MCPInstaller.parseStatus(output)
        XCTAssertTrue(status.isWorking, "the bridge itself is fine — alerts work")
        XCTAssertNotNil(status.hooksProblem, "but the sessions list won't, and the row must say so")
    }

    func testHealthyHooksLeaveNoProblem() {
        let output = """
        ---UNAME---
        Darwin
        arm64
        ---BASE---
        /Users/Shared
        ---BIN---
        OnyxMCP 0.19 (proto 4)
        ---REG---
        REGISTERED
        ---HOOKS---
        HOOKS_OK /Users/Shared/.onyx/bin/OnyxMCP
        """
        XCTAssertNil(MCPInstaller.parseStatus(output).hooksProblem)
    }

    // MARK: - Where events come from

    private func drainMain() {
        let done = expectation(description: "main")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testEventsAreAttributedToTheirMachineAndAccount() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
            "onyx_origin": ["machine": "spark", "user": "agent", "session": "trainer"],
        ])
        _ = manager.processHookEvent([
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "onyx_origin": ["machine": "spark", "user": "agent", "session": "trainer"],
        ])
        drainMain()

        let source = manager.hookSources["agent@spark"]
        XCTAssertEqual(source?.events, 2)
        XCTAssertEqual(source?.lastEvent, "PostToolUse")
        XCTAssertEqual(source?.sessions, ["s1"])
        XCTAssertEqual(manager.sessions["s1"]?.origin?.session, "trainer")
        XCTAssertEqual(ClaudeSessionsSection.place(manager.sessions["s1"]!), "trainer",
                       "the list names the tmux session, not an opaque id")
    }

    /// SessionStart replaces the session's entry; it must not lose the
    /// origin recorded a moment before.
    func testSessionStartKeepsTheOrigin() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent([
            "hook_event_name": "SessionStart", "session_id": "s2",
            "onyx_origin": ["machine": "mac-studio", "user": "me"],
        ])
        drainMain()
        XCTAssertEqual(manager.sessions["s2"]?.origin?.machine, "mac-studio")
        XCTAssertEqual(ClaudeSessionsSection.place(manager.sessions["s2"]!), "mac-studio",
                       "no tmux session → the machine")
    }

    // MARK: - Sessions that end

    private func event(_ name: String, _ id: String, pane: String? = nil,
                       machine: String = "spark") -> [String: Any] {
        var origin: [String: Any] = ["machine": machine, "user": "me", "session": "work"]
        if let pane { origin["pane"] = pane }
        return ["hook_event_name": name, "session_id": id, "onyx_origin": origin]
    }

    /// Quitting Claude sends SessionEnd; the session leaves the list
    /// instead of sitting there for five minutes.
    func testSessionEndRemovesTheSession() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent(event("SessionStart", "a", pane: "%3"))
        _ = manager.processHookEvent(event("SessionEnd", "a", pane: "%3"))
        drainMain()
        XCTAssertNil(manager.sessions["a"])
        XCTAssertTrue(manager.activeSessions.isEmpty)
    }

    /// Open, quit, open, quit, open: one session, not three — even when
    /// no SessionEnd arrives (a killed Claude, or a host whose hooks
    /// predate it). One pane runs one Claude at a time.
    func testANewSessionInTheSamePaneReplacesTheOld() {
        let manager = ClaudeSessionManager()
        for id in ["a", "b", "c"] {
            _ = manager.processHookEvent(event("SessionStart", id, pane: "%3"))
        }
        drainMain()
        XCTAssertEqual(manager.activeSessions.map(\.id), ["c"])
    }

    /// Two Claudes in one tmux session — different panes, or the same pane
    /// id on another machine — are two sessions. An origin without a pane
    /// (an older bridge, or no tmux) replaces nothing.
    func testOtherPanesAndUnknownPanesAreKept() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent(event("SessionStart", "a", pane: "%3"))
        _ = manager.processHookEvent(event("SessionStart", "b", pane: "%4"))
        _ = manager.processHookEvent(event("SessionStart", "c", pane: "%3", machine: "gpu"))
        _ = manager.processHookEvent(event("SessionStart", "d"))
        _ = manager.processHookEvent(event("SessionStart", "e"))
        drainMain()
        XCTAssertEqual(Set(manager.sessions.keys), ["a", "b", "c", "d", "e"])
    }

    func testThePaneSurvivesTheSessionLookup() {
        let origin = HookOrigin(machine: "m", user: "u", pids: [7], pane: "%9")
        XCTAssertEqual(origin.with(session: "work").pane, "%9")
        XCTAssertEqual(HookOrigin(["machine": "m", "pane": "%9"])?.pane, "%9")
        XCTAssertNil(HookOrigin(["machine": "m", "pane": ""])?.pane)
    }

    func testEventsFromOldBridgesAreCountedNotLost() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent(["hook_event_name": "PreToolUse", "session_id": "abcdef1234", "tool_name": "Read"])
        drainMain()
        XCTAssertTrue(manager.hookSources.isEmpty)
        XCTAssertEqual(manager.anonymousHookEvents, 1)
        XCTAssertEqual(ClaudeSessionsSection.place(manager.sessions["abcdef1234"]!), "abcdef12")
    }

    // MARK: - Layout

    /// Claude sessions live in the simple layout's side column now, so
    /// they alone are reason enough for the column to open.
    func testClaudeSessionsOpenTheSimpleSideColumn() {
        let state = AppState()
        _ = state.claudeSessions.processHookEvent(["hook_event_name": "SessionStart",
                                                   "session_id": "layout-\(UUID().uuidString)"])
        drainMain()
        XCTAssertTrue(SimpleSidePanel.hasClaudeSessions(state))
        XCTAssertTrue(SimpleSidePanel.hasContent(appState: state, reminders: RemindersManager()))
    }
}
