import XCTest
@testable import OnyxLib

/// The whole git chain, for real: build the script, run it through
/// RemoteExec, verify execution, clean the output, parse it, and check
/// what the file browser would actually render. Local host, so no SSH is
/// involved — everything else is the production path.
///
/// Every previous fix here was verified on a piece of the chain, and the
/// panel still didn't appear. This exercises all of it at once.
final class GitEndToEndTests: XCTestCase {

    private var repoRoot: String {
        // The package directory, which is itself a git repo.
        URL(fileURLWithPath: #filePath)          // …/Tests/OnyxTests/Managers/this.swift
            .deletingLastPathComponent()          // Managers
            .deletingLastPathComponent()          // OnyxTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root
            .path
    }

    private func localState() -> AppState {
        let state = AppState()
        state.hosts = [.localhost]
        state.activeSession = TmuxSession(name: "t", source: .host(hostID: HostConfig.localhostID))
        return state
    }

    func testCheckAndLoadLightsUpTheRepoPanel() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repoRoot + "/.git"),
                          "needs a real repo to inspect")
        let manager = GitManager(appState: localState())
        manager.checkAndLoad(path: repoRoot)

        // checkAndLoad hops to a background queue and back to main.
        let deadline = Date().addingTimeInterval(20)
        while !manager.isGitRepo && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertTrue(manager.isGitRepo,
                      "the browser shows the git panel only when this is true")
        XCTAssertNotNil(manager.repoStatus, "…and only when there's a status to show")
        XCTAssertFalse(manager.repoStatus?.branch.isEmpty ?? true, "branch should be named")
        XCTAssertEqual(manager.currentRepoPath, repoRoot)
    }

    /// A directory that isn't a repo must NOT light the panel — the same
    /// chain has to produce the negative correctly, or the panel would
    /// appear everywhere.
    func testNonRepoDirectoryLeavesThePanelOff() {
        let manager = GitManager(appState: localState())
        manager.checkAndLoad(path: NSTemporaryDirectory())

        let deadline = Date().addingTimeInterval(20)
        while manager.isLoading && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(manager.isGitRepo)
        XCTAssertNil(manager.repoStatus)
    }

    /// Deep paths are where the payload budget used to break: the script
    /// named the repo path once per git command.
    func testWorksFromADeeplyNestedRepoPath() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: repoRoot + "/.git"),
                          "needs a real repo to inspect")
        let payload = AppState().remoteScript(
            GitManager.statusScript(for: repoRoot + "/Sources/OnyxLib/Managers"),
            host: {
                var h = HostConfig.localhost
                h.id = UUID(); h.ssh.host = "example.com"
                return h
            }()).stdin ?? ""
        XCTAssertLessThan(payload.count, 1024, "\(payload.count)B would be truncated in transit")
    }
}

/// The panel used to be able to be absent with no explanation anywhere —
/// which made "is it broken or was it removed?" unanswerable. These pin
/// the states that must produce a visible reason.
final class GitUnavailableReasonTests: XCTestCase {

    private func remoteState() -> AppState {
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "unreachable.example.com"   // never usable: no pair
        state.hosts = [host]
        state.activeSession = TmuxSession(name: "t", source: .host(hostID: host.id))
        return state
    }

    func testUnusableHostGivesAReasonInsteadOfSilence() {
        let manager = GitManager(appState: remoteState())
        manager.checkAndLoad(path: "/srv/app")
        XCTAssertNotNil(manager.unavailableReason,
                        "no panel AND no explanation is what made this invisible")
        XCTAssertTrue(manager.unavailableReason?.contains("waiting") ?? false)
        XCTAssertFalse(manager.isGitRepo)
    }

    func testSuccessClearsTheReason() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root + "/.git"))

        let state = AppState()
        state.hosts = [.localhost]
        state.activeSession = TmuxSession(name: "t", source: .host(hostID: HostConfig.localhostID))
        let manager = GitManager(appState: state)
        manager.unavailableReason = "stale"
        manager.checkAndLoad(path: root)

        let deadline = Date().addingTimeInterval(20)
        while !manager.isGitRepo && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(manager.isGitRepo)
        XCTAssertNil(manager.unavailableReason, "a working read must clear the notice")
    }

    /// A plain directory is not a failure — it must NOT nag.
    func testOrdinaryNonRepoSaysNothing() {
        let state = AppState()
        state.hosts = [.localhost]
        state.activeSession = TmuxSession(name: "t", source: .host(hostID: HostConfig.localhostID))
        let manager = GitManager(appState: state)
        manager.checkAndLoad(path: NSTemporaryDirectory())

        let deadline = Date().addingTimeInterval(20)
        while manager.isLoading && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(manager.isGitRepo)
        XCTAssertNil(manager.unavailableReason)
    }

    func testClearResetsEverything() {
        let manager = GitManager(appState: remoteState())
        manager.checkAndLoad(path: "/srv/app")
        XCTAssertNotNil(manager.unavailableReason)
        manager.clear()
        XCTAssertNil(manager.unavailableReason)
    }
}
