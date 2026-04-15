//
// BrowserManager.swift
//
// Responsibility: Owns one WKWebView per browser-typed TmuxSession and exposes
//                 the active view's URL/title/loading state to SwiftUI.
// Scope: Per-window (lives on AppState).
// Threading: Main actor for @Published mutations; KVO callbacks bounce through
//            DispatchQueue.main.async before touching state.
// Invariants:
//   - At most one activeSessionID at a time; kvoObservations always belong to
//     the currently active web view
//   - activate(sessionID:) MUST NOT be called from SwiftUI updateNSView — only
//     from makeNSView or user actions (would otherwise loop)
//   - destroySession removes both the web view and its delegate
//
// See: ADR-002 (KVO pattern for WKWebView state propagation)
//

import SwiftUI
import WebKit
import Combine

// MARK: - Browser Manager

/// Manages WKWebView instances for browser sessions.
/// State properties are updated via KVO on the active web view,
/// NOT during SwiftUI updateNSView (which would cause infinite loops).
public class BrowserManager: ObservableObject {
    @Published public var currentURL: String = ""
    @Published public var currentTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false

    private var webViews: [String: WKWebView] = [:]
    private var activeSessionID: String?
    private var delegates: [String: BrowserDelegate] = [:]
    private var kvoObservations: [NSKeyValueObservation] = []

    /// Called when the active session's URL host changes (e.g. navigating from
    /// github.com to google.com). The callback receives (sessionID, newHost)
    /// so the owner can update the session name in allSessions.
    public var onHostChanged: ((String, String) -> Void)?

    /// Create a new instance.
    public init() {}

    /// Get or create the web view for a session
    public func webView(for session: TmuxSession) -> WKWebView {
        if let existing = webViews[session.id] {
            return existing
        }

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true

        let delegate = BrowserDelegate(manager: self, sessionID: session.id)
        wv.navigationDelegate = delegate
        delegates[session.id] = delegate
        webViews[session.id] = wv

        // Load initial URL
        if let urlStr = session.source.browserURL, let url = URL(string: urlStr) {
            wv.load(URLRequest(url: url))
        }

        return wv
    }

    /// Switch to a session — sets up KVO on the new web view.
    /// MUST NOT be called from updateNSView; call from makeNSView or user actions only.
    public func activate(sessionID: String) {
        guard sessionID != activeSessionID else { return }
        activeSessionID = sessionID

        // Remove old KVO observations
        kvoObservations.removeAll()

        guard let wv = webViews[sessionID] else { return }

        // Observe WKWebView properties via KVO — updates arrive outside SwiftUI's update cycle
        kvoObservations.append(wv.observe(\.url, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newURL = wv.url?.absoluteString ?? ""
                let oldHost = URL(string: self.currentURL)?.host
                let newHost = wv.url?.host
                self.currentURL = newURL
                // Notify owner when the host changes so the session name can update
                if let sid = self.activeSessionID, let nh = newHost, nh != oldHost {
                    self.onHostChanged?(sid, nh)
                }
            }
        })
        kvoObservations.append(wv.observe(\.title, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.currentTitle = wv.title ?? "" }
        })
        kvoObservations.append(wv.observe(\.isLoading, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.isLoading = wv.isLoading }
        })
        kvoObservations.append(wv.observe(\.canGoBack, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.canGoBack = wv.canGoBack }
        })
        kvoObservations.append(wv.observe(\.canGoForward, options: .new) { [weak self] wv, _ in
            DispatchQueue.main.async { self?.canGoForward = wv.canGoForward }
        })

        // Set initial state
        currentURL = wv.url?.absoluteString ?? ""
        currentTitle = wv.title ?? ""
        isLoading = wv.isLoading
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
    }

    /// Navigate.
    public func navigate(to urlString: String) {
        guard let id = activeSessionID, let wv = webViews[id],
              let url = Self.normalizeURL(urlString) else { return }
        wv.load(URLRequest(url: url))
    }

    /// Turn a URL-bar string into a URL: bare hosts get https://, anything
    /// else with spaces or without a dot becomes a Google search.
    /// Extracted for testability.
    public static func normalizeURL(_ input: String) -> URL? {
        var urlStr = input.trimmingCharacters(in: .whitespaces)
        guard !urlStr.isEmpty else { return nil }

        if !urlStr.contains("://") {
            if urlStr.contains(".") && !urlStr.contains(" ") {
                urlStr = "https://\(urlStr)"
            } else {
                urlStr = "https://www.google.com/search?q=\(urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr)"
            }
        }
        return URL(string: urlStr)
    }

    /// Go back.
    public func goBack() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.goBack()
    }

    /// Go forward.
    public func goForward() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.goForward()
    }

    /// Reload.
    public func reload() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.reload()
    }

    /// Destroy session.
    public func destroySession(_ sessionID: String) {
        if sessionID == activeSessionID {
            kvoObservations.removeAll()
            activeSessionID = nil
        }
        webViews.removeValue(forKey: sessionID)
        delegates.removeValue(forKey: sessionID)
    }
}

// MARK: - Navigation Delegate

private class BrowserDelegate: NSObject, WKNavigationDelegate {
    weak var manager: BrowserManager?
    let sessionID: String

    init(manager: BrowserManager, sessionID: String) {
        self.manager = manager
        self.sessionID = sessionID
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
}
