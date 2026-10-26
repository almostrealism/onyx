import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Renaming a session used to leave the old name in the list beside the
/// new one: the topology store and the still-running terminal both kept
/// the old id alive.
final class SessionRenameTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    private let host = UUID()

    func testTheNewNameTakesTheOldOnesPlace() {
        let app = AppState()
        let a = TmuxSession(name: "a", source: .host(hostID: host))
        let old = TmuxSession(name: "old", source: .host(hostID: host))
        let c = TmuxSession(name: "c", source: .host(hostID: host))
        app.allSessions = [a, old, c]
        app.sessionConnectionStates[old.id] = .reattaching(reason: "x", since: Date())

        let renamed = TmuxSession(name: "new", source: .host(hostID: host))
        app.replaceRenamedSession(oldID: old.id, with: renamed)

        XCTAssertEqual(app.allSessions.map(\.name), ["a", "new", "c"])
        XCTAssertNil(app.sessionConnectionStates[old.id])
        XCTAssertNotNil(app.sessionConnectionStates[renamed.id])
    }

    func testAnEnumerationThatAlreadyFoundTheNewNameLeavesOneCopy() {
        let app = AppState()
        let old = TmuxSession(name: "old", source: .host(hostID: host))
        let renamed = TmuxSession(name: "new", source: .host(hostID: host))
        app.allSessions = [old, renamed]
        app.replaceRenamedSession(oldID: old.id, with: renamed)
        XCTAssertEqual(app.allSessions.map(\.name), ["new"])
    }

    func testTheTopologyStoreForgetsTheOldName() {
        let store = NetworkTopologyStore.shared
        let old = TmuxSession(name: "rename-test-old-\(UUID().uuidString.prefix(6))",
                              source: .host(hostID: host))
        store.mergeEnumeration(hostID: host, sessions: [old], probeResult: .ok)
        XCTAssertTrue(store.deriveSessions().contains { $0.id == old.id })

        AppState().replaceRenamedSession(
            oldID: old.id, with: TmuxSession(name: "renamed", source: .host(hostID: host)))
        XCTAssertFalse(store.deriveSessions().contains { $0.id == old.id })
    }

    func testTheIdleClockFollowsTheRename() {
        let store = TerminalActivityStore.shared
        let from = "rename-\(UUID())", to = "rename-\(UUID())"
        store.recordExternal(sessionID: from, at: Date(timeIntervalSinceNow: -30))
        store.rename(from: from, to: to)
        XCTAssertNil(store.lastOutput(for: from))
        XCTAssertNotNil(store.lastOutput(for: to))
    }
}
