import SwiftUI

public struct ContentView: View {
    @StateObject private var appState = AppState()

    public init() {}

    private var hasOverlay: Bool {
        appState.showNotes || appState.showSetup || appState.showSettings
            || appState.showCommandPalette || appState.showFileBrowser || appState.showSessionManager
    }

    public var body: some View {
        ZStack {
            // Dark tint — opacity driven by settings, desktop shows through
            Color(nsColor: NSColor(white: 0.04, alpha: 1.0))
                .opacity(appState.appearance.windowOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Terminal always underneath
            TerminalHostView(appState: appState)
                .opacity(hasOverlay ? 0.3 : 1.0)
                .allowsHitTesting(!hasOverlay)

            // Monitor overlay — blur terminal for privacy, then show stats
            if appState.showMonitor {
                VibrancyBackground()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                MonitorView(appState: appState)
                    .transition(.opacity)
            }

            // Connection error overlay
            if appState.connectionError != nil {
                ConnectionErrorOverlay(appState: appState)
            }

            // Reconnecting indicator
            if appState.isReconnecting && appState.connectionError == nil {
                ReconnectingOverlay(accentColor: appState.accentColor)
            }

            // Notes panel slides from right
            if appState.showNotes {
                NotesView(appState: appState)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }

            // File browser slides from left
            if appState.showFileBrowser {
                FileBrowserView(appState: appState)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            // Session manager slides from left
            if appState.showSessionManager {
                SessionManagerView(appState: appState)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            // Setup screen
            if appState.showSetup {
                SetupView(appState: appState)
                    .transition(.opacity)
            }

            // Settings
            if appState.showSettings {
                SettingsView(appState: appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Window rename dialog
            if appState.showWindowRename {
                WindowRenameView(appState: appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Command palette
            if appState.showCommandPalette {
                CommandPaletteView(appState: appState)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Favorites bar — bottom
            if !appState.showSetup && !hasOverlay {
                VStack {
                    Spacer()
                    FavoritesBar(appState: appState)
                        .padding(.bottom, 28)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showNotes)
        .animation(.easeInOut(duration: 0.2), value: appState.showSettings)
        .animation(.easeInOut(duration: 0.2), value: appState.showMonitor)
        .animation(.easeInOut(duration: 0.15), value: appState.showCommandPalette)
        .animation(.easeInOut(duration: 0.2), value: appState.showSetup)
        .animation(.easeInOut(duration: 0.2), value: appState.showFileBrowser)
        .animation(.easeInOut(duration: 0.2), value: appState.showSessionManager)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appState.loadConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNotes)) { _ in
            appState.showCommandPalette = false
            appState.showSettings = false
            appState.showNotes.toggle()
            ShortcutManager.notesVisible = appState.showNotes
        }
        .onReceive(NotificationCenter.default.publisher(for: .createNote)) { _ in
            appState.showCommandPalette = false
            appState.showSettings = false
            appState.showNotes = true
            ShortcutManager.notesVisible = true
            appState.createNoteRequested = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
            appState.showCommandPalette.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMonitor)) { _ in
            appState.showMonitor.toggle()
            ShortcutManager.monitorVisible = appState.showMonitor
            updateWindowTitle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFileBrowser)) { _ in
            appState.showCommandPalette = false
            appState.showSettings = false
            appState.showFileBrowser.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSessionManager)) { _ in
            appState.showCommandPalette = false
            appState.showSettings = false
            appState.showSessionManager.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            appState.showCommandPalette = false
            appState.showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
            let wasMonitoring = appState.showMonitor
            appState.dismissTopOverlay()
            ShortcutManager.monitorVisible = appState.showMonitor
            ShortcutManager.notesVisible = appState.showNotes
            if wasMonitoring && !appState.showMonitor {
                updateWindowTitle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleTmuxSession)) { _ in
            let sessions = appState.allSessions
            guard sessions.count > 1, let current = appState.activeSession else { return }
            if let idx = sessions.firstIndex(where: { $0.id == current.id }) {
                let next = sessions[(idx + 1) % sessions.count]
                appState.switchToSession = next
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .createTmuxSession)) { _ in
            appState.createNewSession = true
        }
        .onChange(of: appState.appearance.windowTitle) { _, _ in
            updateWindowTitle()
        }
        .onChange(of: appState.activeSession?.id) { _, _ in
            updateWindowTitle()
        }
    }

    private func updateWindowTitle() {
        DispatchQueue.main.async {
            NSApplication.shared.windows.first?.title = appState.effectiveWindowTitle
        }
    }
}

struct ReconnectingOverlay: View {
    let accentColor: Color
    @State private var dotCount = 0
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("Reconnecting" + String(repeating: ".", count: dotCount % 4))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                Spacer()
            }
            Spacer()
        }
        .allowsHitTesting(false)
        .onReceive(timer) { _ in
            dotCount += 1
        }
    }
}

struct ConnectionErrorOverlay: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: appState.needsKeySetup ? "key.fill" : "wifi.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundColor(appState.needsKeySetup ? appState.accentColor : Color(hex: "FF6B6B"))

                Text(appState.needsKeySetup ? "SSH KEY REQUIRED" : "CONNECTION FAILED")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.needsKeySetup ? appState.accentColor : Color(hex: "FF6B6B"))
                    .tracking(3)

                Text(appState.connectionError ?? "")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 460)

                if appState.needsKeySetup {
                    Button(action: {
                        appState.keySetupInProgress = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 12))
                            Text("Install SSH Key")
                                .font(.system(.body, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(appState.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)

                    Text("You'll enter your password once, then it's key-based from here.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                }

                Text("⌘K → Reconnect SSH  |  ⌘, → Edit Settings")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(appState.accentColor.opacity(0.5))
                    .padding(.top, 4)
            }
            .padding(30)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke((appState.needsKeySetup ? appState.accentColor : Color(hex: "FF6B6B")).opacity(0.3), lineWidth: 1)
            )

            Spacer()
        }
    }
}

struct FavoritesBar: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Session manager toggle
            Button(action: {
                appState.showSessionManager.toggle()
            }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(appState.accentColor.opacity(0.6))
                    .frame(width: 22, height: 18)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            // Connection indicator + host
            HStack(spacing: 5) {
                Circle()
                    .fill(appState.connectionError != nil ? Color(hex: "FF6B6B") :
                          appState.isReconnecting ? Color(hex: "FFD06B") : Color(hex: "6BFF8E"))
                    .frame(width: 5, height: 5)

                Text(appState.sshConfig.host.isEmpty ? "local" : appState.sshConfig.host)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(.trailing, 6)

            // Favorite session tabs
            ForEach(appState.favoriteSessions, id: \.id) { session in
                let isActive = appState.activeSession?.id == session.id
                Button(action: {
                    if !isActive {
                        appState.switchToSession = session
                    }
                }) {
                    Text(session.displayLabel)
                        .font(.system(size: 10, weight: isActive ? .medium : .regular, design: .monospaced))
                        .foregroundColor(isActive ? appState.accentColor : .gray.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isActive ? appState.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }

            // Active session indicator (if not in favorites)
            if let active = appState.activeSession, !appState.isFavorited(active) {
                Text(active.displayLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(appState.accentColor.opacity(0.12))
                    .cornerRadius(4)
            }

            Spacer()

            // Hint
            Text("⌘J sessions")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray.opacity(0.25))
                .padding(.trailing, 4)

            if appState.allSessions.count > 1 {
                Text("⇧⇥ switch")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.25))
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal, 12)
    }
}
