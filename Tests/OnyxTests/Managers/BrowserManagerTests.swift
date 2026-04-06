import XCTest
@testable import OnyxLib

// MARK: - Browser Session Tests

final class BrowserSessionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    func testBrowserSessionSource_properties() {
        let source = SessionSource.browser(url: "https://github.com")
        XCTAssertTrue(source.isBrowser)
        XCTAssertFalse(source.isDocker)
        XCTAssertFalse(source.isUtility)
        XCTAssertEqual(source.hostID, HostConfig.localhostID)
        XCTAssertEqual(source.browserURL, "https://github.com")
        XCTAssertEqual(source.displayName, "github.com")
    }

    func testBrowserSession_displayLabel() {
        let session = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        XCTAssertEqual(session.displayLabel, "github.com")
    }

    func testBrowserSession_stableKey() {
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        XCTAssertTrue(session.id.contains("browser:"))
    }

    func testBrowserManager_createWebView() {
        let manager = BrowserManager()
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        let wv = manager.webView(for: session)
        XCTAssertNotNil(wv)

        // Getting the same session returns the same view
        let wv2 = manager.webView(for: session)
        XCTAssertTrue(wv === wv2)
    }

    func testBrowserManager_activate_doesNotCrash() {
        let manager = BrowserManager()
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        _ = manager.webView(for: session)

        // This should not hang or crash
        manager.activate(sessionID: session.id)
        // URL may or may not be set depending on WKWebView loading state
        XCTAssertNotNil(manager.currentURL)
    }

    func testBrowserManager_destroySession() {
        let manager = BrowserManager()
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        _ = manager.webView(for: session)
        manager.activate(sessionID: session.id)

        manager.destroySession(session.id)
        // Should not crash, state should be cleared
    }

    func testBrowserSession_inAllSessions() {
        let state = AppState()
        let browser = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        let terminal = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))

        state.allSessions = [terminal, browser]
        state.activeSession = browser

        // Active session should be the browser
        XCTAssertTrue(state.activeSession?.source.isBrowser == true)
    }

    func testBrowserSession_switchDoesNotModifyPublishedDuringUpdate() {
        // Verify that activate() with a new session ID doesn't cause issues
        // when called outside of updateNSView
        let manager = BrowserManager()
        let s1 = TmuxSession(name: "a", source: .browser(url: "https://a.com"))
        let s2 = TmuxSession(name: "b", source: .browser(url: "https://b.com"))
        _ = manager.webView(for: s1)
        _ = manager.webView(for: s2)

        manager.activate(sessionID: s1.id)
        manager.activate(sessionID: s2.id)
        manager.activate(sessionID: s1.id)
        // Should not hang or crash with rapid switching
    }
}

