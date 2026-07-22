import XCTest
@testable import OnyxLib

// MARK: - Session Independence Tests
//
// Connection truth is per-session (`AppState.sessionConnectionStates`),
// written only by the terminal session manager. These tests lock the
// invariant that one session's state never bleeds into another's overlay,
// and that unknown sessions read as connected (no spurious overlay).

final class SessionIndependenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    private let hostA = UUID()
    private let hostB = UUID()

    func testReconnectingOverlay_onlyAffectsThatSession() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        state.sessionConnectionStates[sessionA.id] = .reattaching(reason: "test", since: Date())

        state.activeSession = sessionA
        XCTAssertTrue(state.isActiveSessionReconnecting)

        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testConnectionError_onlyAffectsThatSession() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        state.sessionConnectionStates[sessionA.id] = .failed(error: "Connection failed")

        state.activeSession = sessionA
        XCTAssertTrue(state.activeSessionHasError)
        XCTAssertEqual(state.activeSessionErrorMessage, "Connection failed")

        state.activeSession = sessionB
        XCTAssertFalse(state.activeSessionHasError)
        XCTAssertNil(state.activeSessionErrorMessage)
    }

    func testUnknownSession_readsAsConnected() {
        let state = AppState()
        let session = TmuxSession(name: "fresh", source: .host(hostID: hostA))
        state.activeSession = session

        // No entry in sessionConnectionStates — must NOT show any overlay.
        XCTAssertEqual(state.activeSessionConnectionState, .connected)
        XCTAssertFalse(state.isActiveSessionReconnecting)
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testNoActiveSession_readsAsConnected() {
        let state = AppState()
        state.activeSession = nil
        XCTAssertEqual(state.activeSessionConnectionState, .connected)
        XCTAssertFalse(state.isActiveSessionReconnecting)
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testBrowserSession_notAffectedBySSHReconnect() {
        let state = AppState()
        let terminal = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let browser = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        state.allSessions = [terminal, browser]

        state.sessionConnectionStates[terminal.id] = .reattaching(reason: "test", since: Date())

        state.activeSession = browser
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testClearingState_returnsToConnected() {
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: hostA))
        state.allSessions = [session]
        state.activeSession = session

        state.sessionConnectionStates[session.id] = .failed(error: "boom")
        XCTAssertTrue(state.activeSessionHasError)

        state.sessionConnectionStates[session.id] = nil
        XCTAssertFalse(state.activeSessionHasError)
        XCTAssertEqual(state.activeSessionConnectionState, .connected)
    }
}

// MARK: - Reconnection Safety Tests

final class ReconnectionSafetyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    private let hostA = UUID()
    private let hostB = UUID()

    func testReconnecting_doesNotAffectDifferentHostSession() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        state.sessionConnectionStates[sessionA.id] = .reattaching(reason: "lost", since: Date())

        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)

        state.activeSession = sessionA
        XCTAssertTrue(state.isActiveSessionReconnecting)
    }

    func testSwitchingSession_overlayFollowsActiveSession() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]
        state.activeSession = sessionA

        state.sessionConnectionStates[sessionA.id] = .reattaching(reason: "lost", since: Date())
        XCTAssertTrue(state.isActiveSessionReconnecting)

        // User switches to session B — overlay disappears, but session A's
        // truth is untouched (it IS still reattaching).
        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)
        XCTAssertEqual(
            state.sessionConnectionStates[sessionA.id],
            state.sessionConnectionStates[sessionA.id] // still present
        )
        if case .reattaching = state.sessionConnectionStates[sessionA.id] ?? .connected {
            // expected
        } else {
            XCTFail("session A state should remain .reattaching")
        }
    }

    func testMultipleSessions_independentErrors() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        state.sessionConnectionStates[sessionA.id] = .failed(error: "Host A failed")

        state.activeSession = sessionA
        XCTAssertTrue(state.activeSessionHasError)
        XCTAssertEqual(state.activeSessionErrorMessage, "Host A failed")

        state.activeSession = sessionB
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testErrorAndReattaching_areMutuallyExclusivePerSession() {
        // One dict, one value per session — a session can't be both
        // "reconnecting" and "failed" (the old two-flag system could).
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: hostA))
        state.allSessions = [session]
        state.activeSession = session

        state.sessionConnectionStates[session.id] = .reattaching(reason: "lost", since: Date())
        state.sessionConnectionStates[session.id] = .failed(error: "gave up")

        XCTAssertFalse(state.isActiveSessionReconnecting)
        XCTAssertTrue(state.activeSessionHasError)
    }

    func testRemoveHost_dropsThatHostsSessionStates() {
        let state = AppState()
        let host = HostConfig(
            label: "test-host",
            ssh: SSHConfig(host: "h", user: "u", port: 22, tmuxSession: "main")
        )
        state.hosts.append(host)
        let session = TmuxSession(name: "dev", source: .host(hostID: host.id))
        let other = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [session, other]
        state.sessionConnectionStates[session.id] = .failed(error: "x")
        state.sessionConnectionStates[other.id] = .failed(error: "y")

        state.removeHost(host.id)

        XCTAssertNil(state.sessionConnectionStates[session.id])
        XCTAssertNotNil(state.sessionConnectionStates[other.id])
    }
}
