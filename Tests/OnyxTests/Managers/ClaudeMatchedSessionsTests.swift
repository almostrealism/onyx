import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Matched sessions: a tmux session Onyx tracks, joined with the Claudes
/// its hooks place there (docs/claude-matched-sessions-plan.md).
final class ClaudeMatchedSessionsTests: XCTestCase {

    // MARK: - Helpers

    private func claude(_ id: String, machine: String = "spark", user: String? = "me",
                        session: String? = "work", pane: String? = "%1",
                        ago: TimeInterval = 0, status: ClaudeActivity.ClaudeStatus = .idle) -> ClaudeActivity {
        var activity = ClaudeActivity(id: id, lastSeen: Date().addingTimeInterval(-ago), status: status)
        activity.origin = HookOrigin(machine: machine, user: user, session: session, pane: pane)
        return activity
    }

    private func candidate(_ id: String, user: String = "me", names: [String] = ["spark"],
                           session: String = "work") -> ClaudeMatchCandidate {
        ClaudeMatchCandidate(sessionID: id, user: user, machineNames: names, session: session)
    }

    private func drainMain() {
        let done = expectation(description: "main")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Matching

    func testAClaudeMatchesTheOneSessionThatFits() {
        let matches = ClaudeSessionMatching.match(
            [claude("a")],
            candidates: [candidate("s1"), candidate("s2", session: "other"),
                         candidate("s3", names: ["elsewhere"])])
        XCTAssertEqual(matches.claudes(in: "s1").map(\.id), ["a"])
        XCTAssertTrue(matches.unmatched.isEmpty)
    }

    /// Two hosts both called something like "spark" with a "work" session:
    /// the Claude could be in either, so it's in neither.
    func testAnAmbiguousFitIsNoFit() {
        let matches = ClaudeSessionMatching.match(
            [claude("a")],
            candidates: [candidate("s1"), candidate("s2", names: ["spark.lan"])])
        XCTAssertTrue(matches.bySession.isEmpty)
        XCTAssertEqual(matches.unmatched.map(\.id), ["a"])
    }

    /// The account settles a tie between two accounts on one machine.
    func testTheAccountSettlesATie() {
        let matches = ClaudeSessionMatching.match(
            [claude("a", user: "ops")],
            candidates: [candidate("s1", user: "me"), candidate("s2", user: "ops")])
        XCTAssertEqual(matches.claudes(in: "s2").map(\.id), ["a"])
    }

    /// A Claude under `su` reports the account it became; the machine and
    /// the session still single the session out.
    func testAnotherAccountStillMatchesWhenNothingElseFits() {
        let matches = ClaudeSessionMatching.match(
            [claude("a", user: "root")], candidates: [candidate("s1", user: "me")])
        XCTAssertEqual(matches.claudes(in: "s1").map(\.id), ["a"])
    }

    /// The hook sends the short hostname; the host may be configured by its
    /// full name, or by an alias whose only link is the learned hostname.
    func testTheMachineMatchesAFullNameOrALearnedOne() {
        XCTAssertEqual(ClaudeSessionMatching.sessionID(
            for: claude("a").origin!, in: [candidate("s1", names: ["spark.example.com"])]), "s1")
        XCTAssertEqual(ClaudeSessionMatching.sessionID(
            for: claude("a").origin!, in: [candidate("s1", names: ["10.0.0.4", "spark"])]), "s1")
        XCTAssertNil(ClaudeSessionMatching.sessionID(
            for: claude("a").origin!, in: [candidate("s1", names: ["sparkle"])]),
                     "a longer name is a different machine")
    }

    func testAClaudeOutsideTmuxIsUnmatched() {
        let matches = ClaudeSessionMatching.match(
            [claude("a", session: nil)], candidates: [candidate("s1")])
        XCTAssertEqual(matches.unmatched.map(\.id), ["a"])
    }

    func testSeveralClaudesInOneSessionAreAllThere() {
        let matches = ClaudeSessionMatching.match(
            [claude("old", pane: "%1", ago: 60), claude("new", pane: "%2")],
            candidates: [candidate("s1")])
        XCTAssertEqual(matches.claudes(in: "s1").map(\.id), ["new", "old"])
        XCTAssertEqual(matches.sessionID(of: "old"), "s1")
    }

    /// Waiting for permission speaks first, then running, then the latest.
    func testTheClaudeThatNeedsYouLeadsTheLine() {
        let idle = claude("idle")
        let running = claude("run", ago: 30, status: .running(tool: "Bash"))
        let waiting = claude("wait", ago: 90, status: .waitingPermission)
        XCTAssertEqual(ClaudeActivityLine.lead(of: [idle, running, waiting])?.id, "wait")
        XCTAssertEqual(ClaudeActivityLine.lead(of: [idle, running])?.id, "run")
        XCTAssertEqual(ClaudeActivityLine.lead(of: [claude("x", ago: 50), idle])?.id, "idle")
    }

    // MARK: - Lifetime

    /// A Claude that will say when it ends stays while it sits quiet at its
    /// prompt; one that won't fades after five minutes as before.
    func testAQuietClaudeThatReportsItsEndStaysLive() {
        let manager = ClaudeSessionManager()
        manager.sessions["new"] = claude("new", ago: 1800)
        manager.sessions["old"] = claude("old", pane: nil, ago: 1800)
        XCTAssertEqual(manager.liveSessions.map(\.id), ["new"])
        XCTAssertTrue(manager.activeSessions.isEmpty, "the unmatched list keeps its five minutes")
    }

    func testAPaneCheckEndsAClaude() {
        let manager = ClaudeSessionManager()
        manager.sessions["a"] = claude("a", ago: 1800)
        manager.ended(["a"])
        drainMain()
        XCTAssertTrue(manager.liveSessions.isEmpty)
    }

    /// gc used to drop everything after an hour — including a Claude that
    /// is still there and will say when it isn't.
    func testGCKeepsAQuietClaudeThatReportsItsEnd() {
        let manager = ClaudeSessionManager()
        manager.sessions["new"] = claude("new", ago: 7200)
        manager.sessions["old"] = claude("old", pane: nil, ago: 7200)
        manager.gc()
        drainMain()
        XCTAssertEqual(Set(manager.sessions.keys), ["new"])
    }

    // MARK: - The pane check

    func testThePaneCheckParsesPanesAndSkipsTheEcho() {
        let output = """
        tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{session_name}' 2>/dev/null
        %1 claude work
        %2 zsh my session
        """
        let panes = ClaudePaneCheck.parse(output)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes["%2"], ClaudePaneCheck.Pane(command: "zsh", session: "my session"))
    }

    func testThePaneCheckEndsOnlyOnADefiniteAnswer() {
        let panes = ClaudePaneCheck.parse("%1 claude work\n%2 -zsh work\n%3 node other\n")
        let origin = { (pane: String?) in HookOrigin(machine: "spark", user: "me", session: "work", pane: pane) }
        XCTAssertFalse(ClaudePaneCheck.hasEnded(origin("%1"), panes: panes), "still running Claude")
        XCTAssertTrue(ClaudePaneCheck.hasEnded(origin("%2"), panes: panes), "back at a login shell")
        XCTAssertTrue(ClaudePaneCheck.hasEnded(origin("%9"), panes: panes),
                      "its pane closed while its session is still there")
        XCTAssertFalse(ClaudePaneCheck.hasEnded(origin("%3"), panes: panes),
                       "anything that isn't a shell may be Claude under another name")
        XCTAssertFalse(ClaudePaneCheck.hasEnded(origin(nil), panes: panes), "no pane, no verdict")
        let elsewhere = HookOrigin(machine: "spark", user: "me", session: "gone", pane: "%9")
        XCTAssertFalse(ClaudePaneCheck.hasEnded(elsewhere, panes: panes),
                       "a session this tmux doesn't have may be on another server")
        XCTAssertFalse(ClaudePaneCheck.hasEnded(origin("%9"), panes: [:]),
                       "an empty answer says nothing")
    }

    func testTheRemoteScriptsAreSafeInAnInteractiveShell() {
        for script in [ClaudePaneCheck.script, HostMachineNames.script] {
            XCTAssertFalse(script.contains("!"), "history expansion eats the line")
            XCTAssertFalse(script.contains("*"), "an unmatched glob is fatal in zsh")
            XCTAssertLessThan(script.utf8.count, 200)
        }
    }

    // MARK: - Learned hostnames

    func testTheHostnameIsReadFromItsMarkerNotTheEcho() {
        XCTAssertEqual(HostMachineNames.shortName(from: "echo \"ONYX-HOST=$(hostname)\"\nONYX-HOST=spark.example.com\n"),
                       "spark")
        XCTAssertEqual(HostMachineNames.shortName(from: "ONYX-HOST=Mac-Studio\necho \"ONYX-HOST=$(hostname)\""),
                       "Mac-Studio", "the echo of the last line can land after the output")
        XCTAssertNil(HostMachineNames.shortName(from: "echo \"ONYX-HOST=$(hostname)\""))
    }

    func testLearnedHostnamesPersist() {
        let suite = "onyx-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        HostMachineNames(defaults: defaults).record("ONYX-HOST=spark.lan", for: id)
        XCTAssertEqual(HostMachineNames(defaults: defaults).name(for: id), "spark")
    }

    // MARK: - The sessions list

    private let host = HostConfig(label: "spark", ssh: SSHConfig(host: "spark", user: "me"))

    private func makeState(_ sessions: [TmuxSession]) -> AppState {
        let state = AppState()
        FavoritesStore.shared.reset()
        SessionNotesStore.shared.reset()
        state.hosts = [host]
        state.allSessions = sessions
        return state
    }

    /// A matched session is listed with or without a note; an unmatched,
    /// unnoted one isn't.
    func testAMatchedSessionIsListedWithoutANote() {
        let work = TmuxSession(name: "work", source: .host(hostID: host.id))
        let idle = TmuxSession(name: "idle", source: .host(hostID: host.id))
        let state = makeState([work, idle])
        let matches = ClaudeSessionMatching.match([claude("a")], candidates: state.claudeMatchCandidates())
        let rows = orderedSessionNotes(appState: state, matches: matches)
        XCTAssertEqual(rows.map(\.session.name), ["work"])
        XCTAssertNil(rows.first?.note)
        XCTAssertEqual(rows.first?.title, work.displayLabel)
        XCTAssertEqual(rows.first?.claudes.map(\.id), ["a"])
    }

    /// The idle clock counts a Claude's hooks, not only the terminal.
    func testLastActivityIsTheLaterOfTerminalAndHooks() {
        let work = TmuxSession(name: "work", source: .host(hostID: host.id))
        let state = makeState([work])
        let heard = claude("a", ago: 5)
        let matches = ClaudeSessionMatching.match([heard], candidates: state.claudeMatchCandidates())
        let last = state.lastActivity(for: work, in: matches)
        XCTAssertNotNil(last)
        if let terminal = TerminalActivityStore.shared.lastOutput(for: work.id) {
            XCTAssertEqual(last, max(terminal, heard.lastSeen))
        } else {
            XCTAssertEqual(last, heard.lastSeen)
        }
    }

    /// Only Claudes no session claims go to CLAUDE SESSIONS.
    func testTheClaudeListKeepsOnlyTheUnmatched() {
        let work = TmuxSession(name: "work", source: .host(hostID: host.id))
        let state = makeState([work])
        let matches = ClaudeSessionMatching.match(
            [claude("mine"), claude("stray", machine: "unknown"),
             claude("faded", machine: "unknown", ago: 600)],
            candidates: state.claudeMatchCandidates())
        XCTAssertEqual(state.unmatchedClaudes(matches).map(\.id), ["stray"])
    }
}
