import SwiftUI
import WebKit

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
