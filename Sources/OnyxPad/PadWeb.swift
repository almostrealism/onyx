//
// PadWeb.swift
//
// Responsibility: Web tabs on the iPad — the Mac's browser tabs, for a
//                 dashboard, a PR, a dev server — beside the terminals.
// Scope: PadWebTab per tab (kept in a window's PadWorkspace); the view is
//        iOS-only, a placeholder on the Mac.
//
// The WKWebView is kept on its tab, like a terminal's view, so switching
// tabs doesn't reload the page. Its title and address are read by KVO, never
// through @Published state during an update — the re-entry loop the Mac's
// BrowserManager learned to avoid.
//

import Foundation
import SwiftUI

public final class PadWebTab: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public var url: URL
    @Published public var title: String?
    /// The platform view, kept across tab switches.
    public var hostView: AnyObject?
    var observations: [NSKeyValueObservation] = []

    public init(url: URL) {
        self.url = url
    }

    public var label: String {
        if let title, !title.isEmpty { return title }
        return url.host ?? url.absoluteString
    }

    /// What someone typed, as a URL: a bare host gets https, anything with
    /// spaces or no dot is not a URL.
    public static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        let host = text.split(separator: "/").first.map(String.init) ?? text
        guard host.contains(".") || host.hasPrefix("localhost") else { return nil }
        return URL(string: "https://" + text)
    }
}

#if canImport(UIKit)
import WebKit

struct PadWebView: UIViewRepresentable {
    @ObservedObject var tab: PadWebTab

    func makeUIView(context: Context) -> WKWebView {
        if let kept = tab.hostView as? WKWebView { return kept }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        let tab = self.tab
        tab.observations = [
            view.observe(\.title, options: [.new]) { [weak tab] web, _ in
                DispatchQueue.main.async { tab?.title = web.title }
            },
            view.observe(\.url, options: [.new]) { [weak tab] web, _ in
                DispatchQueue.main.async { if let url = web.url { tab?.url = url } }
            },
        ]
        view.load(URLRequest(url: tab.url))
        tab.hostView = view
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
}

#else

struct PadWebView: View {
    @ObservedObject var tab: PadWebTab
    var body: some View {
        Text(tab.url.absoluteString).foregroundColor(.gray).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif

/// A web tab with its address bar.
struct PadWebScreen: View {
    @ObservedObject var tab: PadWebTab
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: { tab.back() }) { Image(systemName: "chevron.left") }
                Button(action: { tab.forward() }) { Image(systemName: "chevron.right") }
                Button(action: { tab.reloadPage() }) { Image(systemName: "arrow.clockwise") }
                TextField("Address", text: $address)
                    .font(.system(size: 13, design: .monospaced))
                    .codeEntry()
                    .onSubmit(go)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(5)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 6)
            PadWebView(tab: tab)
        }
        .onAppear { address = tab.url.absoluteString }
        .onChange(of: tab.url) { _, url in address = url.absoluteString }
    }

    private func go() {
        guard let url = PadWebTab.url(from: address) else { return }
        tab.open(url)
    }
}

#if canImport(UIKit)
extension PadWebTab {
    private var web: WKWebView? { hostView as? WKWebView }
    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func reloadPage() { web?.reload() }
    func open(_ next: URL) { url = next; web?.load(URLRequest(url: next)) }
}
#else
extension PadWebTab {
    func back() {}
    func forward() {}
    func reloadPage() {}
    func open(_ next: URL) { url = next }
}
#endif
