import SwiftUI
import SceneKit

public struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var showStartupAnimation = true

    public init() {}

    /// True overlays that dim/block the terminal (not right panels)
    private var hasOverlay: Bool {
        appState.showSetup || appState.showSettings
            || appState.showCommandPalette || appState.showSessionManager
    }

    @ViewBuilder
    private func rightPanelView(for panel: RightPanel) -> some View {
        switch panel {
        case .notes:
            NotesView(appState: appState)
        case .fileBrowser:
            FileBrowserView(appState: appState)
        case .artifacts:
            ArtifactView(appState: appState)
        }
    }

    /// Fraction of window width for the right panel (0.0–0.85)
    @State private var rightPanelFraction: CGFloat = 0.6

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Dark tint — opacity driven by settings, desktop shows through
                Color(nsColor: NSColor(white: 0.04, alpha: 1.0))
                    .opacity(appState.appearance.windowOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Split layout: terminal left, panel right
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        // LEFT: Terminal area
                        ZStack {
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
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(FocusOutline(active: appState.focusedComponent == .terminal, show: appState.showFocusOutline))

                        // RIGHT: Side panel with draggable divider
                        if let panel = appState.activeRightPanel {
                            // Drag handle
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 6)
                                .contentShape(Rectangle())
                                .overlay(
                                    Rectangle()
                                        .fill(appState.accentColor.opacity(0.15))
                                        .frame(width: 1)
                                )
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.resizeLeftRight.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            let totalWidth = geo.size.width
                                            guard totalWidth > 0 else { return }
                                            // Drag left = panel grows, drag right = panel shrinks
                                            let panelWidth = totalWidth - value.location.x
                                            let fraction = panelWidth / totalWidth
                                            rightPanelFraction = min(max(fraction, 0.2), 0.85)
                                        }
                                )

                            rightPanelView(for: panel)
                                .frame(width: geo.size.width * rightPanelFraction)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .modifier(FocusOutline(active: appState.focusedComponent == .rightPanel, show: appState.showFocusOutline))
                        }
                    }
                }

                // Full-window overlays on top of everything

                // Session manager slides from left
                if appState.showSessionManager {
                    SessionManagerView(appState: appState)
                        .modifier(FocusOutline(active: appState.focusedComponent == .sessionManager, show: appState.showFocusOutline))
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
                        .modifier(FocusOutline(active: appState.focusedComponent == .settings, show: appState.showFocusOutline))
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
                        .modifier(FocusOutline(active: appState.focusedComponent == .commandPalette, show: appState.showFocusOutline))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Favorites bar — outside terminal area at the bottom
            if !appState.showSetup && !showStartupAnimation {
                FavoritesBar(appState: appState)
            }
        }
        .overlay {
            if showStartupAnimation {
                StartupOverlay(accentHex: appState.appearance.accentHex)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .modifier(ContentViewAnimations(appState: appState))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appState.loadConfig()
            // Dismiss startup animation after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.6)) {
                    showStartupAnimation = false
                }
            }
        }
        .modifier(ContentViewNotifications(appState: appState, updateWindowTitle: updateWindowTitle))
    }

    private func updateWindowTitle() {
        DispatchQueue.main.async {
            NSApplication.shared.windows.first?.title = appState.effectiveWindowTitle
        }
    }
}

// MARK: - Startup Animation

private struct StartupOverlay: View {
    let accentHex: String

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.03, alpha: 1.0))
                .ignoresSafeArea()

            VStack(spacing: 24) {
                SpinningCubeView(accentHex: accentHex)
                    .frame(width: 120, height: 120)

                Text("ONYX")
                    .font(.system(size: 18, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .tracking(12)
            }
        }
    }
}

private struct SpinningCubeView: NSViewRepresentable {
    let accentHex: String

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scnView.scene = scene

        // Wireframe cube
        let box = SCNBox(width: 1.2, height: 1.2, length: 1.2, chamferRadius: 0.05)
        let material = SCNMaterial()
        material.fillMode = .lines
        material.diffuse.contents = NSColor(hex: accentHex)?.withAlphaComponent(0.7) ?? NSColor.cyan
        material.isDoubleSided = true
        box.materials = [material]

        let cubeNode = SCNNode(geometry: box)
        scene.rootNode.addChildNode(cubeNode)

        // Spin animation — continuous rotation on two axes
        let rotateX = SCNAction.rotateBy(x: .pi * 2, y: 0, z: 0, duration: 6)
        let rotateY = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 4)
        cubeNode.runAction(.repeatForever(rotateX))
        cubeNode.runAction(.repeatForever(rotateY))

        // Subtle ambient + directional light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = NSColor(white: 0.3, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light?.type = .directional
        dirLight.light?.color = NSColor(white: 0.8, alpha: 1.0)
        dirLight.eulerAngles = SCNVector3(x: -.pi / 4, y: .pi / 4, z: 0)
        scene.rootNode.addChildNode(dirLight)

        // Camera
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(x: 0, y: 0, z: 3)
        scene.rootNode.addChildNode(camera)
        scnView.pointOfView = camera

        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {}
}

private extension NSColor {
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard h.count == 6, let int = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255.0,
            green: CGFloat((int >> 8) & 0xFF) / 255.0,
            blue: CGFloat(int & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

// MARK: - Focus Debug Outline

private struct FocusOutline: ViewModifier {
    let active: Bool
    let show: Bool

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.orange, lineWidth: 2)
                .opacity(active && show ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Extracted Modifiers (keeps body type-checkable)

private struct ContentViewAnimations: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .animation(.easeInOut(duration: 0.2), value: appState.activeRightPanel)
            .animation(.easeInOut(duration: 0.2), value: appState.showSettings)
            .animation(.easeInOut(duration: 0.2), value: appState.showMonitor)
            .animation(.easeInOut(duration: 0.15), value: appState.showCommandPalette)
            .animation(.easeInOut(duration: 0.2), value: appState.showSetup)
            .animation(.easeInOut(duration: 0.2), value: appState.showSessionManager)
    }
}

private struct ContentViewNotifications: ViewModifier {
    @ObservedObject var appState: AppState
    let updateWindowTitle: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleNotes)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .notes ? nil : .notes
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNote)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = .notes
                appState.createNoteRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
                appState.showCommandPalette.toggle()
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleMonitor)) { _ in
                appState.showMonitor.toggle()
                ShortcutManager.monitorVisible = appState.showMonitor
                updateWindowTitle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFileBrowser)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .fileBrowser ? nil : .fileBrowser
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSessionManager)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.showSessionManager.toggle()
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleArtifacts)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .artifacts ? nil : .artifacts
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                appState.showCommandPalette = false
                appState.showSettings = true
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
                let wasMonitoring = appState.showMonitor
                appState.dismissTopOverlay()
                ShortcutManager.monitorVisible = appState.showMonitor
                if wasMonitoring && !appState.showMonitor { updateWindowTitle() }
            }
            .modifier(ContentViewSessionNotifications(appState: appState))
            .onChange(of: appState.activeRightPanel) { _, newValue in
                ShortcutManager.rightPanelVisible = newValue != nil
                appState.recalculateFocus()
            }
            .onChange(of: appState.showSettings) { _, _ in
                appState.recalculateFocus()
            }
            .onChange(of: appState.showCommandPalette) { _, _ in
                appState.recalculateFocus()
            }
            .onChange(of: appState.showSessionManager) { _, _ in
                appState.recalculateFocus()
            }
            .onChange(of: appState.appearance.windowTitle) { _, _ in updateWindowTitle() }
            .onChange(of: appState.activeSession?.id) { _, _ in updateWindowTitle() }
    }
}

private struct ContentViewSessionNotifications: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cycleTmuxSession)) { _ in
                let favorites = appState.favoriteSessions
                guard favorites.count > 1, let current = appState.activeSession else { return }
                if let idx = favorites.firstIndex(where: { $0.id == current.id }) {
                    let next = favorites[(idx + 1) % favorites.count]
                    appState.switchToSession = next
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createTmuxSession)) { _ in
                appState.showSessionManager = true
                appState.showNewSessionPrompt = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshSession)) { _ in
                appState.reconnectRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToFavorite)) { notification in
                guard let index = notification.object as? Int else { return }
                let favorites = appState.favoriteSessions
                guard index <= favorites.count else { return }
                let session = favorites[index - 1]
                if appState.activeSession?.id != session.id {
                    appState.switchToSession = session
                }
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

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    var body: some View {
        HStack(spacing: 0) {
            // Session manager toggle
            Button(action: {
                appState.showSessionManager.toggle()
            }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: sz(10), weight: .medium))
                    .foregroundColor(appState.accentColor.opacity(0.6))
                    .frame(width: sz(22), height: sz(18))
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            // Window number badge
            if appState.windowIndex <= 3 {
                Text("\(appState.windowIndex + 1)")
                    .font(.system(size: sz(8), weight: .bold, design: .monospaced))
                    .foregroundColor(appState.accentColor.opacity(0.5))
                    .frame(width: sz(14), height: sz(14))
                    .background(appState.accentColor.opacity(0.1))
                    .cornerRadius(3)
                    .padding(.trailing, 4)
            }

            // Connection indicator + host
            HStack(spacing: 5) {
                Circle()
                    .fill(appState.connectionError != nil ? Color(hex: "FF6B6B") :
                          appState.isReconnecting ? Color(hex: "FFD06B") : Color(hex: "6BFF8E"))
                    .frame(width: 5, height: 5)

                Text(appState.activeHost?.label ?? "local")
                    .font(.system(size: sz(10), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .padding(.trailing, 6)

            // Favorite session tabs
            ForEach(Array(appState.favoriteSessions.enumerated()), id: \.element.id) { index, session in
                let isActive = appState.activeSession?.id == session.id
                Button(action: {
                    if !isActive {
                        appState.switchToSession = session
                    }
                }) {
                    HStack(spacing: 4) {
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: sz(8), design: .monospaced))
                                .foregroundColor(.gray.opacity(0.3))
                        }
                        Text(session.displayLabel)
                            .font(.system(size: sz(10), weight: isActive ? .medium : .regular, design: .monospaced))
                            .foregroundColor(isActive ? appState.accentColor : .gray.opacity(0.5))
                    }
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
                    .font(.system(size: sz(10), weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(appState.accentColor.opacity(0.12))
                    .cornerRadius(4)
            }

            Spacer()

            // Hint
            Text("⌘R refresh")
                .font(.system(size: sz(9), design: .monospaced))
                .foregroundColor(.gray.opacity(0.25))
                .padding(.trailing, 4)

            Text("⌘J sessions")
                .font(.system(size: sz(9), design: .monospaced))
                .foregroundColor(.gray.opacity(0.25))
                .padding(.trailing, 4)

            if appState.favoriteSessions.count > 1 {
                Text("⇧⇥ switch")
                    .font(.system(size: sz(9), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.25))
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: NSColor(white: 0.04, alpha: 1.0)))
    }
}
