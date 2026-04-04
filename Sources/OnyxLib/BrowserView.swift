import SwiftUI
import WebKit

// MARK: - Browser Manager

/// Manages WKWebView instances for browser sessions, similar to how
/// OnyxTerminalView pools terminal views for tmux sessions.
public class BrowserManager: ObservableObject {
    @Published public var currentURL: String = ""
    @Published public var currentTitle: String = ""
    @Published public var isLoading: Bool = false
    @Published public var canGoBack: Bool = false
    @Published public var canGoForward: Bool = false

    private var webViews: [String: WKWebView] = [:] // session ID → web view
    private var activeSessionID: String?
    private var delegates: [String: BrowserDelegate] = [:]

    public init() {}

    /// Get or create the web view for a session
    public func webView(for session: TmuxSession) -> WKWebView {
        if let existing = webViews[session.id] {
            return existing
        }

        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true

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

    /// Switch to showing a specific session's web view
    public func activate(session: TmuxSession) {
        activeSessionID = session.id
        if let wv = webViews[session.id] {
            updateState(from: wv)
        }
    }

    /// Navigate the active browser to a URL
    public func navigate(to urlString: String) {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        var urlStr = urlString.trimmingCharacters(in: .whitespaces)

        // Add https:// if no scheme
        if !urlStr.contains("://") {
            if urlStr.contains(".") && !urlStr.contains(" ") {
                urlStr = "https://\(urlStr)"
            } else {
                // Treat as search
                urlStr = "https://www.google.com/search?q=\(urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr)"
            }
        }

        guard let url = URL(string: urlStr) else { return }
        wv.load(URLRequest(url: url))
    }

    public func goBack() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.goBack()
    }

    public func goForward() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.goForward()
    }

    public func reload() {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        wv.reload()
    }

    /// Remove a browser session's web view
    public func destroySession(_ sessionID: String) {
        webViews.removeValue(forKey: sessionID)
        delegates.removeValue(forKey: sessionID)
    }

    fileprivate func updateState(from wv: WKWebView) {
        currentURL = wv.url?.absoluteString ?? ""
        currentTitle = wv.title ?? ""
        isLoading = wv.isLoading
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
    }

    fileprivate func didUpdate(sessionID: String, wv: WKWebView) {
        if sessionID == activeSessionID {
            DispatchQueue.main.async {
                self.updateState(from: wv)
            }
        }
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        manager?.didUpdate(sessionID: sessionID, wv: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        manager?.didUpdate(sessionID: sessionID, wv: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        manager?.didUpdate(sessionID: sessionID, wv: webView)
    }
}

// MARK: - Browser Host View

struct BrowserHostView: NSViewRepresentable {
    @ObservedObject var appState: AppState
    @ObservedObject var browserManager: BrowserManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(gray: 0.04, alpha: 1)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let session = appState.activeSession, session.source.isBrowser else {
            // Remove all web views when not in browser mode
            for sub in container.subviews { sub.removeFromSuperview() }
            return
        }

        let wv = browserManager.webView(for: session)
        browserManager.activate(session: session)

        // If this web view isn't already a subview, add it
        if wv.superview !== container {
            for sub in container.subviews { sub.removeFromSuperview() }
            wv.frame = container.bounds
            wv.autoresizingMask = [.width, .height]
            container.addSubview(wv)
        }
    }
}

// MARK: - URL Bar

struct URLBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browserManager: BrowserManager
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Back/Forward
            Button(action: { browserManager.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(browserManager.canGoBack ? appState.accentColor : .gray.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!browserManager.canGoBack)

            Button(action: { browserManager.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(browserManager.canGoForward ? appState.accentColor : .gray.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!browserManager.canGoForward)

            Button(action: { browserManager.reload() }) {
                Image(systemName: browserManager.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .buttonStyle(.plain)

            // URL field
            TextField("Search or enter URL...", text: $appState.urlBarText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(4)
                .focused($isFocused)
                .onSubmit {
                    browserManager.navigate(to: appState.urlBarText)
                    isFocused = false
                }
                .onReceive(NotificationCenter.default.publisher(for: .focusURLBar)) { _ in
                    isFocused = true
                    appState.urlBarText = browserManager.currentURL
                }

            // Page title (truncated)
            if !browserManager.currentTitle.isEmpty && !isFocused {
                Text(browserManager.currentTitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: 200)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
        .onChange(of: browserManager.currentURL) { _, newURL in
            if !isFocused {
                appState.urlBarText = newURL
            }
        }
    }
}
