import XCTest
@testable import OnyxLib

// MARK: - Session Independence Tests

final class SessionIndependenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    private let hostA = UUID()
    private let hostB = UUID()

    func testReconnectingOverlay_onlyAffectsActiveHost() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        // Reconnecting on host A
        state.isReconnecting = true
        state.reconnectingHostID = hostA

        // When session A is active, should show reconnecting
        state.activeSession = sessionA
        XCTAssertTrue(state.isActiveSessionReconnecting)

        // When session B is active, should NOT show reconnecting
        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testConnectionError_onlyAffectsActiveHost() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        // Error on host A
        state.connectionErrorHostID = hostA
        state.connectionError = "Connection failed"

        // When session A is active, should show error
        state.activeSession = sessionA
        XCTAssertTrue(state.activeSessionHasError)

        // When session B is active, should NOT show error
        state.activeSession = sessionB
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testClearingConnectionError_clearsHostID() {
        let state = AppState()
        state.connectionErrorHostID = hostA
        state.connectionError = "Connection failed"
        XCTAssertNotNil(state.connectionErrorHostID)

        state.connectionError = nil
        XCTAssertNil(state.connectionErrorHostID)
    }

    func testClearingReconnecting_clearsHostID() {
        let state = AppState()
        state.reconnectingHostID = hostA
        state.isReconnecting = true
        XCTAssertNotNil(state.reconnectingHostID)

        state.isReconnecting = false
        XCTAssertNil(state.reconnectingHostID)
    }

    func testBrowserSession_notAffectedBySSHReconnect() {
        let state = AppState()
        let terminal = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let browser = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        state.allSessions = [terminal, browser]

        state.isReconnecting = true
        state.reconnectingHostID = hostA

        // Browser session should not show reconnecting
        state.activeSession = browser
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testBrowserSession_notAffectedByConnectionError() {
        let state = AppState()
        let browser = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        state.allSessions = [browser]

        state.connectionErrorHostID = hostA
        state.connectionError = "SSH failed"

        state.activeSession = browser
        // Browser hostID is localhostID, not hostA
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testNoReconnecting_whenNoHostIDSet() {
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: hostA))
        state.activeSession = session

        state.isReconnecting = true
        // reconnectingHostID not set
        XCTAssertFalse(state.isActiveSessionReconnecting)
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

        // Host A is reconnecting
        state.reconnectingHostID = hostA
        state.isReconnecting = true

        // Active session is on host B — should NOT show reconnecting
        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)

        // Switch to host A — should show reconnecting
        state.activeSession = sessionA
        XCTAssertTrue(state.isActiveSessionReconnecting)
    }

    func testConnectionError_doesNotAffectDifferentHostSession() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        // Host A has error
        state.connectionErrorHostID = hostA
        state.connectionError = "Failed"

        // Active on host B — no error shown
        state.activeSession = sessionB
        XCTAssertFalse(state.activeSessionHasError)

        // Active on host A — error shown
        state.activeSession = sessionA
        XCTAssertTrue(state.activeSessionHasError)
    }

    func testSwitchingSession_clearsReconnectingForOldHost() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]
        state.activeSession = sessionA

        // Start reconnecting for host A
        state.reconnectingHostID = hostA
        state.isReconnecting = true
        XCTAssertTrue(state.isActiveSessionReconnecting)

        // User switches to session B — overlay should disappear
        state.activeSession = sessionB
        XCTAssertFalse(state.isActiveSessionReconnecting)
        // But isReconnecting is still true (host A is still reconnecting)
        XCTAssertTrue(state.isReconnecting)
    }

    func testReconnecting_noOverlayWithoutHostID() {
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: hostA))
        state.activeSession = session

        // isReconnecting but no hostID — should not show overlay
        state.isReconnecting = true
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testConnectionError_noOverlayWithoutHostID() {
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: hostA))
        state.activeSession = session

        state.connectionError = "Error"
        // No connectionErrorHostID set
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testBrowserSession_neverShowsReconnecting() {
        let state = AppState()
        let browser = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        state.activeSession = browser
        state.reconnectingHostID = hostA
        state.isReconnecting = true

        // Browser is on localhostID, reconnecting is for hostA
        XCTAssertFalse(state.isActiveSessionReconnecting)
    }

    func testMultipleHosts_independentErrors() {
        let state = AppState()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "work", source: .host(hostID: hostB))
        state.allSessions = [sessionA, sessionB]

        // Error on host A
        state.connectionErrorHostID = hostA
        state.connectionError = "Host A failed"

        // Session A sees error
        state.activeSession = sessionA
        XCTAssertTrue(state.activeSessionHasError)
        XCTAssertEqual(state.connectionError, "Host A failed")

        // Session B does NOT see error
        state.activeSession = sessionB
        XCTAssertFalse(state.activeSessionHasError)
    }

    func testClearError_alsoResetsHostID() {
        let state = AppState()
        state.connectionErrorHostID = hostA
        state.connectionError = "Failed"
        XCTAssertNotNil(state.connectionErrorHostID)

        state.connectionError = nil
        XCTAssertNil(state.connectionErrorHostID)
        XCTAssertNil(state.connectionError)
    }

    func testClearReconnecting_alsoResetsHostID() {
        let state = AppState()
        state.reconnectingHostID = hostA
        state.isReconnecting = true
        XCTAssertNotNil(state.reconnectingHostID)

        state.isReconnecting = false
        XCTAssertNil(state.reconnectingHostID)
        XCTAssertFalse(state.isReconnecting)
    }
}

