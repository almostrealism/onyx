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
                appState.showNotes.toggle()
            },
            PaletteAction(title: "New Note", shortcut: "⇧⌘E") {
                appState.showCommandPalette = false
                appState.showNotes = true
                appState.createNoteRequested = true
            },
            PaletteAction(title: "File Browser", shortcut: "⌘O") {
                appState.showCommandPalette = false
                appState.showFileBrowser.toggle()
            },
            PaletteAction(title: "Session Manager", shortcut: "⌘J") {
                appState.showCommandPalette = false
                appState.showSessionManager.toggle()
            },
            PaletteAction(title: "Toggle Monitor", shortcut: "`") {
                appState.showCommandPalette = false
                appState.showMonitor.toggle()
            },
            PaletteAction(title: "Settings", shortcut: "⌘,") {
                appState.showCommandPalette = false
                appState.showSettings = true
            },
            PaletteAction(title: "Rename Window", shortcut: "") {
                appState.showCommandPalette = false
                appState.showWindowRename = true
            },
            PaletteAction(title: "Reconnect SSH", shortcut: "") {
                appState.showCommandPalette = false
                appState.reconnectRequested = true
            },
            PaletteAction(title: "Edit Connection", shortcut: "") {
                appState.showCommandPalette = false
                appState.showSetup = true
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
                }
                .padding(12)
                .background(Color.white.opacity(0.06))

                Divider().background(Color.white.opacity(0.1))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(actions) { action in
                            PaletteRow(action: action)
                                .onTapGesture {
                                    action.action()
                                }
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

struct PaletteRow: View {
    let action: PaletteAction

    var body: some View {
        HStack {
            Text(action.title)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if !action.shortcut.isEmpty {
                Text(action.shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
