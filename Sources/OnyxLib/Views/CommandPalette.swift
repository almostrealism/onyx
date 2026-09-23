import SwiftUI

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String
    let action: () -> Void
}

struct CommandPaletteView: View {
    @ObservedObject var appState: AppState
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var actions: [PaletteAction] {
        let all = [
            PaletteAction(title: "Toggle Notes", shortcut: "⌘E") {
                appState.showCommandPalette = false
                appState.activeRightPanel = appState.activeRightPanel == .notes ? nil : .notes
            },
            PaletteAction(title: "New Note", shortcut: "⇧⌘E") {
                appState.showCommandPalette = false
                appState.activeRightPanel = .notes
                appState.createNoteRequested = true
            },
            PaletteAction(title: "File Browser", shortcut: "⌘O") {
                appState.showCommandPalette = false
                appState.activeRightPanel = appState.activeRightPanel == .fileBrowser ? nil : .fileBrowser
            },
            PaletteAction(title: "Full-Window File Browser", shortcut: "⇧⌘O") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .toggleFullFileBrowser, object: nil)
            },
            PaletteAction(title: "Search Files", shortcut: "⇧⌘F") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .searchFiles, object: nil)
            },
            PaletteAction(title: "Artifacts", shortcut: "⌘D") {
                appState.showCommandPalette = false
                appState.activeRightPanel = appState.activeRightPanel == .artifacts ? nil : .artifacts
            },
            PaletteAction(title: "Session Manager", shortcut: "⌘J") {
                appState.showCommandPalette = false
                appState.showSessionManager.toggle()
            },
            PaletteAction(title: "New Session", shortcut: "") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .createTmuxSession, object: nil)
            },
            // The shortcut shown here is the one the user still has: with
            // ⇧⇥ given back to the terminal, advertising it would be a lie
            // — the action itself works either way.
            PaletteAction(title: "Next Session",
                          shortcut: appState.appearance.shiftTabCyclesSessions ? "⇧⇥" : "") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .cycleTmuxSession, object: nil)
            },
            PaletteAction(title: "Toggle Monitor", shortcut: "`") {
                appState.showCommandPalette = false
                appState.showMonitor.toggle()
            },
            PaletteAction(title: "Edit Session Note", shortcut: "⌘;") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .editSessionNote, object: nil)
            },
            PaletteAction(title: "Selectable Text Mode", shortcut: "⇧⌘C") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .toggleTerminalTextMode, object: nil)
            },
            PaletteAction(title: "Focus URL Bar", shortcut: "⌘L") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .focusURLBar, object: nil)
            },
            PaletteAction(title: "Cycle Panel Size", shortcut: "⌘\\") {
                appState.showCommandPalette = false
                NotificationCenter.default.post(name: .cyclePanelSize, object: nil)
            },
            PaletteAction(title: "Settings", shortcut: "⌘,") {
                appState.showCommandPalette = false
                appState.showSettings = true
            },
            PaletteAction(title: "Keyboard Shortcuts / Help", shortcut: "⌘/") {
                appState.showCommandPalette = false
                appState.showHelp = true
            },
            PaletteAction(title: "Rename Window", shortcut: "") {
                appState.showCommandPalette = false
                appState.showWindowRename = true
            },
            PaletteAction(title: "Reconnect SSH", shortcut: "⌘R") {
                appState.showCommandPalette = false
                appState.reconnectRequested = true
            },
            PaletteAction(title: "Edit Connection", shortcut: "") {
                appState.showCommandPalette = false
                appState.showSetup = true
            },
            // One action, not two. This uploads the bridge, registers it
            // with Claude Code and configures the hooks — they were
            // separate before, which let a host end up with one and not
            // the other and nothing to say which.
            PaletteAction(title: "Install Onyx MCP", shortcut: "") {
                appState.showCommandPalette = false
                appState.installMCPOnActiveHost()
            },
        ]
        if query.isEmpty { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showCommandPalette = false
                }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(appState.accentColor.opacity(0.6))
                        .font(.system(size: 14))

                    TextField("Type a command...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                        .focused($isSearchFocused)
                        // Return runs the top match. Typing three letters
                        // and pressing Return is how a command palette is
                        // used; without this the only way to run anything
                        // was to hit the row with the mouse.
                        .onSubmit { actions.first?.action() }
                }
                .padding(12)
                .background(Color.white.opacity(0.06))

                Divider().background(Color.white.opacity(0.1))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(actions) { action in
                            PaletteRow(action: action)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            .frame(width: 420)
            .background(Color(nsColor: NSColor(white: 0.08, alpha: 0.98)))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(appState.accentColor.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            query = ""
            isSearchFocused = true
        }
    }
}

/// One command.
///
/// A real Button, not a `Text` with `.onTapGesture` on it. The tap
/// gesture version gave no hover feedback at all, so a row that didn't
/// respond was indistinguishable from a row that wasn't meant to be
/// clicked — and the commands with no keyboard shortcut (Install Onyx
/// MCP, New Session, Rename Window) are reachable ONLY by clicking.
struct PaletteRow: View {
    let action: PaletteAction
    @State private var hovering = false

    var body: some View {
        Button(action: action.action) {
            HStack {
                Text(action.title)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.white.opacity(hovering ? 1 : 0.9))

                Spacer()

                if !action.shortcut.isEmpty {
                    Text(action.shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.white.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
