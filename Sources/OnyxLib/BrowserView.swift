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
            DispatchQueue.main.async { self?.currentURL = wv.url?.absoluteString ?? "" }
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

    public func navigate(to urlString: String) {
        guard let id = activeSessionID, let wv = webViews[id] else { return }
        var urlStr = urlString.trimmingCharacters(in: .whitespaces)

        if !urlStr.contains("://") {
            if urlStr.contains(".") && !urlStr.contains(" ") {
                urlStr = "https://\(urlStr)"
            } else {
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

// MARK: - Browser Host View

struct BrowserHostView: NSViewRepresentable {
    @ObservedObject var appState: AppState
    @ObservedObject var browserManager: BrowserManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = CGColor(gray: 0.04, alpha: 1)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let session = appState.activeSession, session.source.isBrowser else {
            for sub in container.subviews { sub.removeFromSuperview() }
            context.coordinator.activeID = nil
            return
        }

        // Only act when the session actually changes — prevents re-entry
        guard session.id != context.coordinator.activeID else { return }
        context.coordinator.activeID = session.id

        let wv = browserManager.webView(for: session)

        // Swap the web view in the container
        for sub in container.subviews { sub.removeFromSuperview() }
        wv.frame = container.bounds
        wv.autoresizingMask = [.width, .height]
        container.addSubview(wv)

        // Activate KVO observation — deferred to avoid modifying @Published during update
        DispatchQueue.main.async {
            browserManager.activate(sessionID: session.id)
        }
    }

    class Coordinator {
        var activeID: String?
    }
}

// MARK: - URL Bar

struct URLBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browserManager: BrowserManager
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
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
