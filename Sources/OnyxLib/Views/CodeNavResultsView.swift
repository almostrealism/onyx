import SwiftUI

/// Bottom panel that renders code-navigation results (subclasses, implementors,
/// references, …) from LSPManager. Selecting a row opens that file and jumps to
/// the line. Styled to match the search-results list.
struct CodeNavResultsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager
    @ObservedObject var lsp: LSPManager

    init(appState: AppState, browser: FileBrowserManager) {
        self.appState = appState
        self.browser = browser
        self.lsp = appState.lsp
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            content
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 260)
        .background(Color(nsColor: NSColor(white: 0.08, alpha: 0.98)))
        .overlay(alignment: .top) { Divider().background(Color.white.opacity(0.12)) }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 11))
                .foregroundColor(appState.accentColor)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            Button(action: { lsp.closePanel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String {
        switch lsp.state {
        case .idle: return "CODE NAVIGATION"
        case .indexing(let root): return "INDEXING \(root)…"
        case .running(let kind): return "\(kind.label.uppercased())…"
        case .results(let kind, let symbol, let groups):
            let n = groups.reduce(0) { $0 + $1.results.count }
            let sym = symbol.map { " of \($0)" } ?? ""
            return "\(kind.label.uppercased())\(sym) — \(n)"
        case .empty(let kind): return "\(kind.label.uppercased()) — none found"
        case .unavailable: return "CODE NAVIGATION"
        case .setupRequired: return "CODE INTELLIGENCE — SETUP"
        case .installing: return "INSTALLING LANGUAGE SERVER…"
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch lsp.state {
        case .indexing, .running:
            busyView(busyLabel)

        case .installing:
            busyView("Downloading jdtls onto the host — this runs once…")

        case .empty:
            message("No results.")

        case .unavailable(let reason):
            message(reason)

        case .setupRequired(let reason, let canInstall):
            VStack(spacing: 12) {
                Text(reason)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.7))
                    .multilineTextAlignment(.center)
                if canInstall {
                    Button {
                        Task { await lsp.installThenRetry() }
                    } label: {
                        Text("Install language server")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(appState.accentColor)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

        case .idle:
            message("Put the cursor on a symbol and choose Navigate.")

        case .results(_, _, let groups):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        groupHeader(group)
                        ForEach(group.results) { result in
                            resultRow(result)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var busyLabel: String {
        if let detail = lsp.indexingDetail { return detail }
        if case .indexing = lsp.state { return "Importing the project — first run can take a moment…" }
        return "Searching…"
    }

    private func busyView(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).colorScheme(.dark)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.gray.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func groupHeader(_ group: NavResultGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundColor(.gray.opacity(0.5))
            Text(group.fileName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func resultRow(_ result: NavResult) -> some View {
        Button {
            browser.openAtLocation(path: result.path, line: result.line)
        } label: {
            HStack(spacing: 8) {
                Text("\(result.line)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(appState.accentColor.opacity(0.7))
                    .frame(minWidth: 34, alignment: .trailing)
                if let name = result.name {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                }
                if let kind = result.kindLabel {
                    Text(kind)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
