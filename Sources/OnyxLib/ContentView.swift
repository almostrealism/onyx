import SwiftUI
import SceneKit

// MARK: - Window Finder

/// Invisible NSView that captures a reference to the hosting NSWindow.
private class WindowFinder: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            onWindow?(window)
        }
    }
}

private struct WindowFinderView: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowFinder {
        let view = WindowFinder()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowFinder, context: Context) {}
}

public struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var showStartupAnimation = true
    @State private var hostWindow: NSWindow?

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
    @State private var rightPanelFraction: CGFloat = 0.4
    /// Preset split ratios for the right panel (fraction of total width)
    private static let panelPresets: [CGFloat] = [0.3, 0.4, 0.5, 0.6, 0.7]

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
                        ZStack {
                            // Show browser or terminal based on active session type
                            if appState.activeSession?.source.isBrowser == true {
                                VStack(spacing: 0) {
                                    URLBar(appState: appState, browserManager: appState.browserManager)
                                    Divider().background(Color.white.opacity(0.1))
                                    BrowserHostView(appState: appState, browserManager: appState.browserManager)
                                }
                                .opacity(hasOverlay ? 0.3 : 1.0)
                                .allowsHitTesting(!hasOverlay)
                            } else {
                                TerminalHostView(appState: appState)
                                    .opacity(hasOverlay ? 0.3 : 1.0)
                                    .allowsHitTesting(!hasOverlay)
                            }

                            // Terminal text mode — selectable text overlay
                            if appState.showTerminalText {
                                TerminalTextOverlay(appState: appState)
                                    .transition(.opacity)
                            }

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

                            // Hooks setup status toast
                            if let status = appState.hooksSetupStatus {
                                VStack {
                                    Spacer()
                                    Text(status)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.black.opacity(0.8))
                                        .cornerRadius(6)
                                        .padding(.bottom, 40)
                                }
                                .transition(.opacity)
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(FocusOutline(active: appState.focusedComponent == .terminal, show: appState.showFocusOutline))

                        // RIGHT: Side panel with draggable divider
                        if let panel = appState.activeRightPanel {
                            // Drag handle — 10pt wide grab area, 1pt visible line
                            Rectangle()
                                .fill(Color.white.opacity(0.001)) // nearly invisible but hittable
                                .frame(width: 10)
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
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let totalWidth = geo.size.width
                                            guard totalWidth > 0 else { return }
                                            // Convert global X to local frame X
                                            let windowOriginX = geo.frame(in: .global).minX
                                            let localX = value.location.x - windowOriginX
                                            let panelWidth = totalWidth - localX
                                            let fraction = panelWidth / totalWidth
                                            rightPanelFraction = min(max(fraction, 0.2), 0.85)
                                        }
                                )
                                .zIndex(10)

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
                StartupOverlay(accentHex: appState.effectiveAccentHex, statusText: appState.startupStatus)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .modifier(ContentViewAnimations(appState: appState))
        .background(WindowFinderView { window in
            hostWindow = window
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appState.loadConfig()
        }
        .onChange(of: appState.activeSession) { _, session in
            // Dismiss startup animation once a session is connected
            if session != nil && showStartupAnimation {
                // Give it a moment so the terminal view initializes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        showStartupAnimation = false
                    }
                }
            }
        }
        .onChange(of: appState.configLoaded) { _, loaded in
            // If config loaded but no SSH needed (setup screen), dismiss animation
            if loaded && appState.showSetup {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        showStartupAnimation = false
                    }
                }
            }
            // Safety timeout: dismiss after 15s no matter what
            if loaded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if showStartupAnimation {
                        withAnimation(.easeOut(duration: 0.6)) {
                            showStartupAnimation = false
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cyclePanelSize)) { _ in
            guard hostWindow?.isKeyWindow == true else { return }
            guard appState.activeRightPanel != nil else { return }
            let current = rightPanelFraction
            let next = Self.panelPresets.first(where: { $0 > current + 0.01 })
                ?? Self.panelPresets.first ?? 0.4
            withAnimation(.easeInOut(duration: 0.2)) {
                rightPanelFraction = next
            }
        }
        .modifier(ContentViewNotifications(appState: appState, updateWindowTitle: updateWindowTitle, hostWindow: hostWindow))
        .onChange(of: hostWindow) { _, window in
            if let window = window {
                ShortcutManager.register(window: window, appState: appState)
            }
        }
        .onDisappear {
            if let window = hostWindow {
                ShortcutManager.unregister(window: window)
            }
        }
    }

    private func updateWindowTitle() {
        DispatchQueue.main.async {
            hostWindow?.title = appState.effectiveWindowTitle
        }
    }
}

// MARK: - Startup Animation

private struct StartupOverlay: View {
    let accentHex: String
    let statusText: String

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

                Text(statusText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: accentHex).opacity(0.5))
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: statusText)
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
    var hostWindow: NSWindow?

    private var isKeyWindow: Bool { hostWindow?.isKeyWindow == true }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .toggleNotes)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .notes ? nil : .notes
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNote)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = .notes
                appState.createNoteRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette.toggle()
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleTerminalTextMode)) { _ in
                guard isKeyWindow else { return }
                if appState.showTerminalText {
                    appState.showTerminalText = false
                    appState.terminalTextContent = ""
                    // Restore terminal focus after dismissing the overlay
                    appState.focusedComponent = .terminal
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: .restoreTerminalFocus, object: nil)
                    }
                } else {
                    // Content will be captured by TerminalHostView.updateNSView
                    appState.terminalTextContent = ""
                    appState.showTerminalText = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleMonitor)) { _ in
                guard isKeyWindow else { return }
                appState.showMonitor.toggle()
                updateWindowTitle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleFileBrowser)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .fileBrowser ? nil : .fileBrowser
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSessionManager)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.showSessionManager.toggle()
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleArtifacts)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = false
                appState.activeRightPanel = appState.activeRightPanel == .artifacts ? nil : .artifacts
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                guard isKeyWindow else { return }
                appState.showCommandPalette = false
                appState.showSettings = true
                appState.recalculateFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .escapePressed)) { _ in
                guard isKeyWindow else { return }
                let wasMonitoring = appState.showMonitor
                appState.dismissTopOverlay()
                if wasMonitoring && !appState.showMonitor { updateWindowTitle() }
                appState.recalculateFocus()
            }
            .modifier(ContentViewSessionNotifications(appState: appState, hostWindow: hostWindow))
            .onChange(of: appState.activeRightPanel) { _, _ in
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
    var hostWindow: NSWindow?

    /// Only respond to keyboard-triggered notifications in the key window
    private var isKeyWindow: Bool {
        hostWindow?.isKeyWindow == true
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cycleTmuxSession)) { _ in
                guard isKeyWindow else { return }
                let favorites = appState.favoriteSessions
                guard favorites.count > 1, let current = appState.activeSession else { return }
                if let idx = favorites.firstIndex(where: { $0.id == current.id }) {
                    let next = favorites[(idx + 1) % favorites.count]
                    appState.switchToSession = next
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createTmuxSession)) { _ in
                guard isKeyWindow else { return }
                appState.showSessionManager = true
                appState.showNewSessionPrompt = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshSession)) { _ in
                guard isKeyWindow else { return }
                appState.reconnectRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToFavorite)) { notification in
                guard isKeyWindow else { return }
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

struct TerminalTextOverlay: View {
    @ObservedObject var appState: AppState

    /// Build attributed string with clickable URLs highlighted.
    /// Handles URLs that wrap across terminal lines by using a regex-based
    /// approach that's immune to NSDataDetector's URL normalization issues.
    private var linkedContent: AttributedString {
        let text = appState.terminalTextContent
        var result = AttributedString(text)
        result.foregroundColor = .white.opacity(0.9)

        // Find URLs using a regex that matches across line boundaries.
        // Terminal wraps break URLs at arbitrary points, so we first build
        // a "unwrapped" version where soft line breaks (non-whitespace on
        // both sides) are removed, detect URLs there, then map back.
        let lines = text.components(separatedBy: "\n")

        // Build unwrapped text and a mapping from unwrapped offset → original offset
        var unwrapped = ""
        var offsetMap: [Int] = [] // unwrapped char index → original char index
        var origOffset = 0

        for (i, line) in lines.enumerated() {
            for (j, ch) in line.enumerated() {
                unwrapped.append(ch)
                offsetMap.append(origOffset + j)
            }
            origOffset += line.count

            if i < lines.count - 1 {
                // Decide: is this a soft wrap (mid-URL) or a real line break?
                let nextLine = lines[i + 1]
                let isSoftWrap = !line.isEmpty && !nextLine.isEmpty
                    && !line.last!.isWhitespace && !nextLine.first!.isWhitespace

                if isSoftWrap {
                    // Don't add \n to unwrapped — join the lines
                } else {
                    unwrapped.append("\n")
                    offsetMap.append(origOffset) // the \n character
                }
                origOffset += 1 // skip past \n in original
            }
        }

        // Detect URLs in the unwrapped text
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }

        let nsUnwrapped = unwrapped as NSString
        let range = NSRange(location: 0, length: nsUnwrapped.length)

        for match in detector.matches(in: unwrapped, range: range) {
            guard let url = match.url,
                  let swiftRange = Range(match.range, in: unwrapped) else { continue }

            // Map each character in the match back to the original text
            let matchStart = unwrapped.distance(from: unwrapped.startIndex, to: swiftRange.lowerBound)
            let matchEnd = unwrapped.distance(from: unwrapped.startIndex, to: swiftRange.upperBound)

            // Apply link to each character's position in the original attributed string
            // Group consecutive original offsets into ranges for efficiency
            var i = matchStart
            while i < matchEnd && i < offsetMap.count {
                let runStart = offsetMap[i]
                var runEnd = runStart + 1
                var j = i + 1
                // Extend run while consecutive in original text
                while j < matchEnd && j < offsetMap.count && offsetMap[j] == runEnd {
                    runEnd += 1
                    j += 1
                }

                // Apply link to this run in the original attributed string
                if runStart < text.count && runEnd <= text.count {
                    let attrStart = result.index(result.startIndex, offsetByCharacters: runStart)
                    let attrEnd = result.index(result.startIndex, offsetByCharacters: runEnd)
                    result[attrStart..<attrEnd].link = url
                    result[attrStart..<attrEnd].foregroundColor = Color(hex: "66CCFF")
                    result[attrStart..<attrEnd].underlineStyle = .single
                }

                i = j
            }
        }

        return result
    }

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.04, alpha: 0.98))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar
                HStack {
                    Text("TERMINAL TEXT")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(appState.accentColor)
                        .tracking(2)

                    Spacer()

                    Text("click URLs to open · ⌘⇧C or Esc to close")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.03))

                Divider().background(Color.white.opacity(0.1))

                // Selectable text content with clickable URLs
                if appState.terminalTextContent.isEmpty {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7).colorScheme(.dark)
                        Text("Capturing terminal text...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    Spacer()
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(linkedContent)
                            .font(.system(size: CGFloat(appState.appearance.effectiveTerminalFontSize), design: .monospaced))
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                NSWorkspace.shared.open(url)
                                return .handled
                            })
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
