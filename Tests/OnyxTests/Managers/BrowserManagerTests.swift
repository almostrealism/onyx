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

    // MARK: - Browsers group surfacing in session list

    /// Regression: browser sessions used to disappear from the session list
    /// when the user had no localhost in their hosts array. They now always
    /// appear under a synthetic "Browsers" host group.
    func testBrowserSessions_appearInSyntheticGroup_withoutLocalhost() {
        let state = AppState()
        state.hosts = []  // no hosts at all
        let b1 = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        let b2 = TmuxSession(name: "claude.ai", source: .browser(url: "https://claude.ai"))
        state.allSessions = [b1, b2]

        let groups = state.hostGroupedSessions
        XCTAssertEqual(groups.count, 1, "Should have one synthetic Browsers group")
        XCTAssertEqual(groups.first?.host.id, HostConfig.browsersID)
        XCTAssertEqual(groups.first?.host.label, "Browsers")
        let sessions = groups.first?.groups.flatMap(\.sessions) ?? []
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.name)), Set(["github.com", "claude.ai"]))
    }

    /// Browsers group is appended at the end alongside real host groups.
    func testBrowserSessions_appearAlongsideRealHosts() {
        let state = AppState()
        let host = HostConfig(id: UUID(), label: "remote")
        state.hosts = [host]
        let term = TmuxSession(name: "dev", source: .host(hostID: host.id))
        let browser = TmuxSession(name: "github.com", source: .browser(url: "https://github.com"))
        state.allSessions = [term, browser]

        let groups = state.hostGroupedSessions
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].host.label, "remote")
        XCTAssertEqual(groups[1].host.label, "Browsers")
        // Browser session must NOT also leak into the remote host group
        let remoteSessions = groups[0].groups.flatMap(\.sessions)
        XCTAssertFalse(remoteSessions.contains(where: { $0.source.isBrowser }))
    }

    /// No browsers → no synthetic group at all (don't show empty section).
    func testBrowsersGroup_omittedWhenNoBrowserSessions() {
        let state = AppState()
        let host = HostConfig(id: UUID(), label: "remote")
        state.hosts = [host]
        state.allSessions = [TmuxSession(name: "dev", source: .host(hostID: host.id))]

        let groups = state.hostGroupedSessions
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].host.label, "remote")
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

    // MARK: - URL normalization regression tests

    /// A bare host with a dot becomes https://
    func testNormalizeURL_bareHost() {
        let url = BrowserManager.normalizeURL("github.com")
        XCTAssertEqual(url?.absoluteString, "https://github.com")
    }

    /// A full URL passes through unchanged
    func testNormalizeURL_fullURL() {
        let url = BrowserManager.normalizeURL("https://example.com/path")
        XCTAssertEqual(url?.absoluteString, "https://example.com/path")
    }

    /// Non-https schemes pass through (http:// works too)
    func testNormalizeURL_httpScheme() {
        let url = BrowserManager.normalizeURL("http://localhost:8080")
        XCTAssertEqual(url?.absoluteString, "http://localhost:8080")
    }

    /// A multi-word query becomes a Google search
    func testNormalizeURL_multiWordSearch() {
        let url = BrowserManager.normalizeURL("swift programming language")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertTrue(url?.query?.contains("swift") ?? false)
    }

    /// A single word without a dot also becomes a search (not a broken host)
    func testNormalizeURL_singleWordSearch() {
        let url = BrowserManager.normalizeURL("claude")
        XCTAssertEqual(url?.host, "www.google.com")
    }

    /// Whitespace gets trimmed
    func testNormalizeURL_trimsWhitespace() {
        let url = BrowserManager.normalizeURL("  github.com  ")
        XCTAssertEqual(url?.absoluteString, "https://github.com")
    }

    /// Empty input returns nil (don't navigate)
    func testNormalizeURL_emptyReturnsNil() {
        XCTAssertNil(BrowserManager.normalizeURL(""))
        XCTAssertNil(BrowserManager.normalizeURL("   "))
    }

    // MARK: - KVO activation regression tests

    /// Regression (ADR-002): activate() must be idempotent — calling it
    /// repeatedly with the same session ID must not re-register KVO
    /// observers, re-fire @Published writes, or cause re-entry.
    func testActivate_idempotentSameSession() {
        let manager = BrowserManager()
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        _ = manager.webView(for: session)
        manager.activate(sessionID: session.id)
        let firstURL = manager.currentURL
        manager.activate(sessionID: session.id)
        manager.activate(sessionID: session.id)
        XCTAssertEqual(manager.currentURL, firstURL,
                       "Re-activating the same session must not mutate state")
    }

    /// Regression (ADR-002): destroying the active session must clear KVO
    /// observations so later destruction of the web view doesn't fire into
    /// a dangling observer.
    func testDestroySession_clearsActiveState() {
        let manager = BrowserManager()
        let session = TmuxSession(name: "test", source: .browser(url: "https://example.com"))
        _ = manager.webView(for: session)
        manager.activate(sessionID: session.id)
        manager.destroySession(session.id)
        // Re-activating a destroyed session should not crash
        manager.activate(sessionID: session.id)
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
