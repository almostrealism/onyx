import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// A Claude started with `su -` inside another account's tmux: its hooks
/// can't ask tmux anything, so they send their ancestor pids, and Onyx —
/// connected as the tmux owner — finds the pane those pids run in.
final class HookPaneLookupTests: XCTestCase {

    // MARK: - The pane list

    func testThePaneListParses() {
        let output = """
        Last login: Tue Oct 21 on ttys004
        48431 worker-rings
        1617 worker-onyx
        79604 a0 rings
        garbage line
        """
        let panes = TmuxPaneLookup.parse(output)
        XCTAssertEqual(panes[48431], "worker-rings")
        XCTAssertEqual(panes[79604], "a0 rings", "a session name may hold a space")
        XCTAssertEqual(panes.count, 3)
    }

    /// The chain the bridge sent from this very machine: Bash tool shell,
    /// claude, zsh, su, sudo, the pane's bash, the tmux server.
    func testTheNearestPaneShellNamesTheSession() {
        let chain = [34417, 49710, 49692, 49683, 49562, 48431, 31575]
        let panes = [48431: "worker-rings", 1617: "worker-onyx"]
        XCTAssertEqual(TmuxPaneLookup.session(ancestors: chain, panes: panes), "worker-rings")
        XCTAssertNil(TmuxPaneLookup.session(ancestors: chain, panes: [1617: "worker-onyx"]))
    }

    /// Nested tmux: the inner pane is nearer, and it is the one you see.
    func testTheInnermostPaneWins() {
        XCTAssertEqual(TmuxPaneLookup.session(ancestors: [10, 20, 30], panes: [30: "outer", 20: "inner"]),
                       "inner")
    }

    func testTheMachineMatchesItsConfiguredHost() {
        XCTAssertTrue(TmuxPaneLookup.hostCouldBe("mac-studio", machine: "Mac-Studio"))
        XCTAssertTrue(TmuxPaneLookup.hostCouldBe("mac-studio.tail1234.ts.net", machine: "Mac-Studio"))
        XCTAssertFalse(TmuxPaneLookup.hostCouldBe("mac-studio-2", machine: "Mac-Studio"))
        XCTAssertFalse(TmuxPaneLookup.hostCouldBe("", machine: "Mac-Studio"))
    }

    // MARK: - The origin

    func testPidsArriveFromTheEvent() throws {
        let json = #"{"onyx_origin":{"machine":"Mac-Studio","user":"worker","pids":[49710,48431]}}"#
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let origin = try XCTUnwrap(HookOrigin(event["onyx_origin"]))
        XCTAssertEqual(origin.pids, [49710, 48431])
        XCTAssertTrue(origin.needsPaneLookup)
        XCTAssertEqual(origin.with(session: "worker-rings").label, "worker@Mac-Studio · worker-rings")
    }

    func testAnOriginThatNamedItsSessionIsNotLookedUp() {
        XCTAssertFalse(HookOrigin(machine: "m", session: "s", pids: [5]).needsPaneLookup)
        XCTAssertFalse(HookOrigin(machine: "m").needsPaneLookup, "an older bridge sends no pids")
    }

    // MARK: - The manager

    private func drainMain() {
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 2)
    }

    func testTheFoundSessionIsShownAndKept() {
        let manager = ClaudeSessionManager()
        let owner = NSObject()
        var asked = 0
        manager.registerPaneLookup(owner: owner) { origin, done in
            asked += 1
            XCTAssertEqual(origin.pids, [7, 8])
            done("worker-rings")
        }
        drainMain()
        let origin = HookOrigin(machine: "Mac-Studio", user: "worker", pids: [7, 8])
        manager.recordOrigin(origin, event: "PreToolUse", sessionId: "abc")
        drainMain()
        drainMain()
        XCTAssertEqual(manager.sessions["abc"]?.origin?.session, "worker-rings")

        // Every later event re-reports the bare origin; the name must stay,
        // and tmux isn't asked again.
        manager.recordOrigin(HookOrigin(machine: "Mac-Studio", user: "worker", pids: [9, 8]),
                             event: "PostToolUse", sessionId: "abc")
        drainMain()
        XCTAssertEqual(manager.sessions["abc"]?.origin?.session, "worker-rings")
        XCTAssertEqual(asked, 1)
    }

    /// A miss is retried a minute later, a few times, and then left alone.
    func testAMissIsRetriedAFewTimesThenLeftAlone() {
        let manager = ClaudeSessionManager()
        let owner = NSObject()
        var asked = 0
        manager.registerPaneLookup(owner: owner) { _, done in asked += 1; done(nil) }
        drainMain()
        let origin = HookOrigin(machine: "m", pids: [7])
        let start = Date()
        for minute in 0..<10 {
            // Two events a minute: only the first may ask.
            for second in [0.0, 30.0] {
                manager.recordOrigin(origin, event: "PreToolUse", sessionId: "s",
                                     at: start.addingTimeInterval(Double(minute) * 60 + second))
                drainMain()
            }
        }
        XCTAssertEqual(asked, ClaudeSessionManager.paneMaxTries)
        XCTAssertNil(manager.sessions["s"]?.origin?.session)
    }

    /// The window that registered closed: the next one takes over.
    func testALaterWindowTakesOverWhenTheFirstIsGone() {
        let manager = ClaudeSessionManager()
        var first: NSObject? = NSObject()
        manager.registerPaneLookup(owner: first!) { _, done in done("from-first") }
        drainMain()
        let second = NSObject()
        manager.registerPaneLookup(owner: second) { _, done in done("from-second") }
        drainMain()
        first = nil
        manager.registerPaneLookup(owner: second) { _, done in done("from-second") }
        drainMain()
        manager.recordOrigin(HookOrigin(machine: "m", pids: [7]), event: "PreToolUse", sessionId: "s")
        drainMain()
        drainMain()
        XCTAssertEqual(manager.sessions["s"]?.origin?.session, "from-second")
        _ = first
    }
}
