import SwiftUI

/// Full-screen reference overlay (Cmd+/) explaining what Onyx does and
/// every keyboard command. Read-only; dismissed with Esc, the same
/// shortcut, or a click outside.
struct HelpOverlay: View {
    @ObservedObject var appState: AppState

    private var accent: Color { appState.accentColor }

    // MARK: - Content data

    private struct Shortcut: Identifiable {
        let id = UUID(); let keys: String; let label: String
    }

    /// Global shortcuts — work anywhere.
    private let globalShortcuts: [Shortcut] = [
        .init(keys: "⌘K", label: "Command palette"),
        .init(keys: "⌘/", label: "This help screen"),
        .init(keys: "`", label: "Toggle the monitor overlay"),
        .init(keys: "⌘,", label: "Settings"),
        .init(keys: "⌘E", label: "Toggle notes  ·  ⇧⌘E new note"),
        .init(keys: "⌘O", label: "File browser  ·  ⇧⌘O full-window"),
        .init(keys: "⌘D", label: "Artifacts panel"),
        .init(keys: "⌘J", label: "Session manager"),
        .init(keys: "⌘;", label: "Edit the active session's note"),
        .init(keys: "⌘L", label: "Focus the browser URL bar"),
        .init(keys: "⌘R", label: "Reconnect / refresh the session"),
        .init(keys: "⌘\\", label: "Cycle the side-panel split width"),
        .init(keys: "⇧⌘C", label: "Selectable terminal-text mode"),
        .init(keys: "⇧⇥", label: "Cycle tmux sessions"),
        .init(keys: "⌘1–9", label: "Switch to a favorite session"),
        .init(keys: "⌘⌃ ←↑↓→", label: "Resize the tmux pane"),
        .init(keys: "Space", label: "Preview the selected file (file browser)"),
        .init(keys: "Esc", label: "Dismiss the top overlay"),
    ]

    /// Single-key shortcuts that only fire while the monitor overlay is up.
    private let monitorShortcuts: [Shortcut] = [
        .init(keys: "S", label: "Simple / full monitor layout"),
        .init(keys: "X", label: "Peek — drop the overlay to near-transparent"),
        .init(keys: "T", label: "Toggle poll interval (5s / 1m)"),
        .init(keys: "M", label: "Toggle the memory chart"),
        .init(keys: "C", label: "Toggle all-containers view"),
        .init(keys: "P", label: "Toggle 12 / 24-hour clock"),
    ]

    private let features: [(String, String)] = [
        ("terminal", "Always-on SSH + tmux sessions with auto-reconnect; Docker container sessions and live log streams; built-in browser sessions."),
        ("gauge.medium", "A work-monitoring overlay: CPU/GPU/memory, Docker stats, GitHub + GitLab PRs & pipelines, Apple Reminders, and Timing.app hours."),
        ("doc.text", "Notes, a remote file browser with git status & search, and an artifacts panel agents push to over MCP."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { appState.showHelp = false }

            VStack(spacing: 18) {
                Text("ONYX")
                    .font(.system(size: 24, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(accent)
                    .tracking(10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // What it is
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("WHAT IS ONYX")
                            ForEach(features, id: \.0) { icon, text in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: icon)
                                        .font(.system(size: 12))
                                        .foregroundColor(accent.opacity(0.7))
                                        .frame(width: 18)
                                    Text(text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        shortcutSection("KEYBOARD SHORTCUTS", globalShortcuts)
                        shortcutSection("WHILE THE MONITOR IS OPEN", monitorShortcuts)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("⌘/ or Esc to close")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
            }
            .padding(28)
            .frame(width: 560)
            .frame(maxHeight: 560)
            .background(Color(nsColor: NSColor(white: 0.08, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accent.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(accent.opacity(0.8))
            .tracking(2)
    }

    private func shortcutSection(_ title: String, _ items: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            VStack(spacing: 5) {
                ForEach(items) { s in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(s.keys)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 92, alignment: .leading)
                        Text(s.label)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
