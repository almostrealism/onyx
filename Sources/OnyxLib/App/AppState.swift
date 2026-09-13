import Foundation
import SwiftUI
import Combine

public extension Notification.Name {
    static let toggleNotes = Notification.Name("toggleNotes")
    static let createNote = Notification.Name("createNote")
    static let toggleCommandPalette = Notification.Name("toggleCommandPalette")
    static let toggleMonitor = Notification.Name("toggleMonitor")
    static let openSettings = Notification.Name("openSettings")
    static let escapePressed = Notification.Name("escapePressed")
    static let toggleMonitorInterval = Notification.Name("toggleMonitorInterval")
    static let toggleFileBrowser = Notification.Name("toggleFileBrowser")
    static let toggleFullFileBrowser = Notification.Name("toggleFullFileBrowser")
    static let toggleFilePreview = Notification.Name("toggleFilePreview")
    static let cycleTmuxSession = Notification.Name("cycleTmuxSession")
    static let createTmuxSession = Notification.Name("createTmuxSession")
    static let toggleSessionManager = Notification.Name("toggleSessionManager")
    static let switchToFavorite = Notification.Name("switchToFavorite")
    static let refreshSession = Notification.Name("refreshSession")
    static let toggleArtifacts = Notification.Name("toggleArtifacts")
    static let restoreTerminalFocus = Notification.Name("restoreTerminalFocus")
    /// Hand the keyboard to the terminal / to the open right panel.
    static let focusTerminal = Notification.Name("focusTerminal")
    static let focusRightPanel = Notification.Name("focusRightPanel")
    /// Take the terminal out of first responder. Moving focus to a panel
    /// has to do this or the terminal keeps swallowing the keystrokes
    /// while the UI claims the panel is focused.
    static let resignTerminalFocus = Notification.Name("resignTerminalFocus")
    static let refreshPoolStatus = Notification.Name("refreshPoolStatus")
    static let toggleMemoryChart = Notification.Name("toggleMemoryChart")
    static let toggleAllContainers = Notification.Name("toggleAllContainers")
    static let toggleClockFormat = Notification.Name("toggleClockFormat")
    static let toggleSimpleMonitor = Notification.Name("toggleSimpleMonitor")
    static let cycleFleetMode = Notification.Name("cycleFleetMode")
    static let toggleMonitorPeek = Notification.Name("toggleMonitorPeek")
    static let toggleRemindersDueSoon = Notification.Name("toggleRemindersDueSoon")
    static let toggleSimpleSidePanel = Notification.Name("toggleSimpleSidePanel")
    static let editSessionNote = Notification.Name("editSessionNote")
    static let focusURLBar = Notification.Name("focusURLBar")
    static let tmuxResizeUp = Notification.Name("tmuxResizeUp")
    static let tmuxResizeDown = Notification.Name("tmuxResizeDown")
    static let tmuxResizeLeft = Notification.Name("tmuxResizeLeft")
    static let tmuxResizeRight = Notification.Name("tmuxResizeRight")
    static let toggleTerminalTextMode = Notification.Name("toggleTerminalTextMode")
    static let cyclePanelSize = Notification.Name("cyclePanelSize")
    static let toggleHelp = Notification.Name("toggleHelp")
    static let showWalkthrough = Notification.Name("showWalkthrough")
    static let searchFiles = Notification.Name("searchFiles")
}

// MARK: - Window Index

/// Tracks which window indices are in use across all AppState instances.
private class WindowIndexPool {
    static let shared = WindowIndexPool()
    private var inUse: Set<Int> = []
    private let lock = NSLock()

    func claim() -> Int {
        lock.lock()
        defer { lock.unlock() }
        for i in 0...3 {
            if !inUse.contains(i) {
                inUse.insert(i)
                return i
            }
        }
        // All 0-3 in use — overflow windows get index 4+ (show all favorites)
        let next = (inUse.max() ?? 0) + 1
        inUse.insert(next)
        return next
    }

    func release(_ index: Int) {
        lock.lock()
        inUse.remove(index)
        lock.unlock()
    }
}

// MARK: - Focus Tracking

/// FocusedComponent.
public enum FocusedComponent: Equatable {
    case terminal
    case rightPanel
    case settings
    case commandPalette
    case sessionManager
    case setup
}

extension AppState {
    /// Compute which component should have focus based on visibility precedence.
    /// Precedence (highest first): settings, commandPalette, monitor, sessionManager, rightPanel, terminal
    public var topVisibleComponent: FocusedComponent {
        if showSettings { return .settings }
        if showCommandPalette { return .commandPalette }
        // Monitor overlay doesn't have text input, so terminal keeps focus
        if showSessionManager { return .sessionManager }
        if showFullFileBrowser { return .rightPanel }
        if activeRightPanel != nil { return .rightPanel }
        return .terminal
    }

    /// Something is drawn over the terminal, so a click in the terminal's
    /// frame isn't a click on the terminal.
    ///
    /// This existed as three hand-maintained lists that had already
    /// drifted: the one used for click routing omitted `showTerminalText`,
    /// which was harmless until clicking started taking first responder —
    /// and then it stole the selection out of ⇧⌘C's selectable view.
    public var terminalIsCovered: Bool {
        showMonitor || showSettings || showCommandPalette || showSessionManager
            || showSetup || showTerminalText
    }

    /// Something other than the terminal legitimately owns the keyboard,
    /// so nothing should be "rescuing" it back.
    ///
    /// Not the same question as `terminalIsCovered`: the monitor overlay
    /// covers the terminal but deliberately leaves it holding the
    /// keyboard, which is what makes its single-key shortcuts work.
    public var keyboardOwnedElsewhere: Bool {
        showSettings || showCommandPalette || showSessionManager || showWindowRename
            || showSessionNoteEditor || showHelp || showWalkthrough || showSetup
            || showTerminalText || showPipelineAdder
    }

    /// Recalculate and set focusedComponent based on current visibility state.
    /// Call this when an overlay opens or closes to ensure correct precedence.
    public func recalculateFocus() {
        let top = topVisibleComponent
        // A right panel is not modal. If the user put the keyboard in the
        // terminal, closing the monitor or the session list must not drag
        // it back to the panel just because the panel happens to be open
        // — that stomping is what made focus feel random. Panels that
        // genuinely want the keyboard claim it when they OPEN, explicitly.
        if top == .rightPanel && focusedComponent == .terminal {
            return
        }
        focusedComponent = top
        if focusedComponent == .terminal {
            NotificationCenter.default.post(name: .restoreTerminalFocus, object: nil)
        }
    }
}

// MARK: - Right Panel

/// RightPanel.
public enum RightPanel: Equatable {
    case notes
    case fileBrowser
    case artifacts
}

/// AppState.
public class AppState: ObservableObject {
    @Published public var hosts: [HostConfig] = []
    /// Appearance config shared across all windows via AppearanceStore singleton
    public var appearance: AppearanceConfig {
        get { AppearanceStore.shared.config }
        set {
            AppearanceStore.shared.config = newValue
            objectWillChange.send()
        }
    }

    /// Window opacity to use right now. Normally the user's setting, but
    /// while the monitor overlay is up and the `x` peek is engaged it
    /// drops to the slider floor so the desktop shows through. Drives the
    /// monitor overlay's tint (see MonitorView / AppearanceConfig).
    public var effectiveWindowOpacity: Double {
        (showMonitor && monitorPeek) ? 0.3 : appearance.windowOpacity
    }

    /// Opacity of the window's backdrop tint in the current mode — the
    /// value the bottom bar matches so it blends in instead of forming a
    /// solid strip at the screen edge. In monitor mode that's the
    /// overlay's (peek-aware) tint; otherwise it's the plain window
    /// opacity. So when the `x` peek drops the overlay to see-through,
    /// the bar goes with it.
    public var backdropTintOpacity: Double {
        showMonitor
            ? AppearanceConfig.monitorTintOpacity(for: effectiveWindowOpacity)
            : appearance.windowOpacity
    }
    @Published public var showSetup = false
    @Published public var activeRightPanel: RightPanel?
    @Published public var showSettings = false
    @Published public var showCommandPalette = false
    /// Full-screen help / keyboard-shortcut reference overlay (Cmd+/).
    @Published public var showHelp = false
    /// Guided tour. Shown once on first launch, and on demand from the
    /// Help menu afterwards.
    @Published public var showWalkthrough = false
    @Published public var showMonitor = false {
        didSet {
            // The session sidebar and the monitor are both overlays on top
            // of the terminal; raising the monitor shouldn't leave the
            // session list stacked over it.
            if showMonitor && showSessionManager { showSessionManager = false }
            // ⇧⌘C draws the terminal's text over the terminal; the monitor
            // draws over everything. Both at once leaves selectable text
            // under an opaque overlay — invisible, still eating clicks.
            if showMonitor && showTerminalText {
                showTerminalText = false
                terminalTextContent = ""
            }
        }
    }
    /// When true, the monitor renders the "simple" layout: same headline
    /// row, but giant CPU/MEM/GPU charts below, a compact strip of the
    /// top-CPU containers along the bottom, and a small weekly Timing
    /// tile in the bottom-right. Toggle with `s` while monitor is open.
    @Published public var monitorLayout: MonitorLayout = .detailed
    /// Which machines the overlay's charts are about (`F`). Independent
    /// of the layout, so "simple mode" and "the whole fleet" compose.
    @Published public var fleetMode: FleetMode = .currentHost
    /// Back-compat shim for the many places that only care whether the
    /// stripped-down single-host layout is up.
    public var showSimpleMonitor: Bool { monitorLayout == .simple }
    /// Temporary "peek" while the monitor overlay is up: drops the
    /// overlay's opacity to the slider floor (0.3) so the user can glance
    /// at the desktop behind it, then restore their chosen opacity.
    /// Toggled by `x`. Auto-clears when the monitor closes.
    @Published public var monitorPeek = false
    /// When true, show the small text-field overlay for editing the
    /// note attached to the active session. Toggled by Cmd+;.
    /// The "add a pipeline" panel, shown over the monitor overlay.
    ///
    /// A panel rather than a popover: the popover version crashed the app
    /// on open, inside AppKit's animated window resize. See
    /// PipelineAdderPanel.swift.
    @Published public var showPipelineAdder = false
    @Published public var showSessionNoteEditor = false
    @Published public var reconnectRequested = false
    @Published public var refreshSessionList = false
    @Published public var createNoteRequested = false
    @Published public var showWindowRename = false
    @Published public var needsKeySetup = false
    @Published public var keySetupInProgress = false
    @Published public var showSessionManager = false
    @Published public var showTerminalText = false {
        didSet {
            // Same rule from the other direction: capturing the terminal's
            // text means you want to read the terminal, not the monitor.
            if showTerminalText && showMonitor { showMonitor = false }
        }
    }
    @Published public var terminalTextContent: String = ""

    /// Per-session connection truth. Single writer: OnyxTerminalView.
    /// Absent key == `.connected` (no spurious overlay for sessions the
    /// manager hasn't touched). Views and computed properties only read.
    @Published public var sessionConnectionStates: [String: SessionConnectionState] = [:]

    /// Connection state of the currently active session.
    public var activeSessionConnectionState: SessionConnectionState {
        guard let id = activeSession?.id else { return .connected }
        return sessionConnectionStates[id] ?? .connected
    }

    /// Whether the "Reconnecting…" overlay applies to the active session.
    public var isActiveSessionReconnecting: Bool {
        activeSessionConnectionState.showReconnectingOverlay
    }

    /// Whether the connection-error overlay applies to the active session.
    public var activeSessionHasError: Bool {
        activeSessionConnectionState.showErrorOverlay
    }

    /// Error text for the active session's error overlay, if any.
    public var activeSessionErrorMessage: String? {
        activeSessionConnectionState.errorMessage
    }

    @Published public var showFullFileBrowser = false
    @Published public var showFilePreview = false
    @Published public var showURLBar = false
    @Published public var urlBarText: String = ""
    @Published public var startupStatus: String = "Initializing..."
    /// Whether to draw the orange focus outline around the active
    /// component. Off by default (it's noisy); flip on in Settings →
    /// Debug when investigating focus-routing issues.
    public var showFocusOutline: Bool {
        get { appearance.showFocusOutline }
        set { appearance.showFocusOutline = newValue }
    }

    /// Tracks which component should logically have keyboard focus.
    /// Updated explicitly when overlays open/close and when the user clicks.
    @Published public var focusedComponent: FocusedComponent = .terminal

    // Convenience accessors for right panel types
    /// Show notes.
    public var showNotes: Bool {
        get { activeRightPanel == .notes }
        set { activeRightPanel = newValue ? .notes : nil }
    }

    /// Show file browser.
    public var showFileBrowser: Bool {
        get { activeRightPanel == .fileBrowser }
        set { activeRightPanel = newValue ? .fileBrowser : nil }
    }

    /// Show artifacts.
    public var showArtifacts: Bool {
        get { activeRightPanel == .artifacts }
        set { activeRightPanel = newValue ? .artifacts : nil }
    }
    @Published public var configLoaded = false

    // Session state
    @Published public var isEnumeratingSessions = false
    @Published public var connectionPool: [ConnectionInfo] = []
    /// Sessions that are in a transient state (reconnecting, enumerating, connecting)
    @Published public var pendingConnections: [ConnectionInfo] = []
    @Published public var allSessions: [TmuxSession] = [] {
        didSet {
            // Telling the legacy key and the identity key apart needs a
            // live session to resolve them against, so the repair can't
            // finish at load — it finishes here, the first time the list
            // arrives. A no-op once there's nothing left to collapse.
            collapseDuplicateFavorites()
        }
    }
    @Published public var activeSession: TmuxSession?
    @Published public var switchToSession: TmuxSession?
    @Published public var createNewSession: TmuxSession?  // session to create, nil = none
    /// The session the user is renaming inline in the session list.
    @Published public var sessionPendingRename: TmuxSession?
    @Published public var showNewSessionPrompt = false
    /// Shared favorites store — all windows read/write through this singleton
    public var favoriteEntries: [FavoriteEntry] {
        get { FavoritesStore.shared.entries }
        set { FavoritesStore.shared.entries = newValue }
    }
    /// Notes manager. Stored, so it lives here rather than with the rest
    /// of the persistence code in AppState+Persistence.swift.
    public lazy var notesManager: NotesManager = {
        NotesManager(directory: notesDirectory)
    }()

    /// File browser manager.
    public lazy var fileBrowserManager: FileBrowserManager = {
        FileBrowserManager(appState: self)
    }()

    /// This window's index (0-3). Windows > 3 show all favorites.
    public let windowIndex: Int

    // Host being edited for key setup
    @Published public var keySetupHostID: UUID?

    private var favoritesCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?
    private var topologyCancellable: AnyCancellable?
    /// Monitor. NOTE: intentionally does NOT forward objectWillChange into
    /// AppState — it publishes every ~5s and forwarding re-rendered the whole
    /// app tree each tick. Views that show monitor data (MonitorView,
    /// MonitorSimpleView) @ObservedObject it directly, scoping redraws to the
    /// overlay subtree.
    public lazy var monitor: MonitorManager = {
        MonitorManager(appState: self)
    }()

    private var lspCancellable: AnyCancellable?
    /// Code navigation (LSP / jdtls). Per-workspace language servers.
    public lazy var lsp: LSPManager = {
        // LSPManager is @MainActor and `lsp` is only ever first accessed on the
        // main thread (Views, host removal), so assume main isolation here.
        MainActor.assumeIsolated {
            let m = LSPManager(appState: self)
            lspCancellable = m.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            // Best-effort: stop remote language servers when the app quits. (The
            // ssh child dying already EOFs jdtls, but this is tidier.)
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak m] _ in
                MainActor.assumeIsolated { m?.shutdownAll() }
            }
            return m
        }
    }()

    private var claudeSessionCancellable: AnyCancellable?
    /// Claude sessions.
    public lazy var claudeSessions: ClaudeSessionManager = {
        let c = ClaudeSessionManager()
        c.gatePermissions = AppearanceStore.shared.config.claudeHooksGatePermissions
        claudeSessionCancellable = c.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return c
    }()

    /// Sync the gate-permissions setting from appearance config into the
    /// session manager. Call after the user toggles the setting in Settings.
    public func syncClaudeGatePermissions() {
        claudeSessions.gatePermissions = appearance.claudeHooksGatePermissions
    }

    private var timingCancellable: AnyCancellable?
    /// Timing.
    public lazy var timing: TimingManager = {
        let t = TimingManager(windowIndex: windowIndex)
        timingCancellable = t.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return t
    }()

    private var browserCancellable: AnyCancellable?
    /// Browser manager.
    public lazy var browserManager: BrowserManager = {
        let b = BrowserManager()
        browserCancellable = b.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        b.onHostChanged = { [weak self] sessionID, newHost in
            self?.updateBrowserSessionName(sessionID: sessionID, newHost: newHost)
        }
        return b
    }()

    /// Update a browser session's name when the URL host changes.
    /// Replaces the session in allSessions with a new instance carrying the
    /// updated name, preserving favorites (which key by source.stableKey:name
    /// — but browser stableKey is "browser:<url>" so name changes are safe).
    private func updateBrowserSessionName(sessionID: String, newHost: String) {
        guard let idx = allSessions.firstIndex(where: { $0.id == sessionID }),
              allSessions[idx].name != newHost else { return }
        let old = allSessions[idx]
        let updated = TmuxSession(name: newHost, source: old.source, unavailable: old.unavailable)
        allSessions[idx] = updated
        if activeSession?.id == sessionID {
            activeSession = updated
        }
        saveLocalSessions()
    }

    /// Docker stats. Like `monitor`, does NOT forward objectWillChange into
    /// AppState (it polls every ~5s while the overlay is open). Its views
    /// (MonitorStatsView, MonitorSimpleView) @ObservedObject it directly.
    public lazy var dockerStats: DockerStatsManager = {
        DockerStatsManager(appState: self)
    }()

    private var artifactCancellable: AnyCancellable?
    /// Artifact manager.
    public lazy var artifactManager: ArtifactManager = {
        let a = ArtifactManager()
        artifactCancellable = a.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return a
    }()

    /// Internal rather than private: the MCP lifecycle helpers live in
    /// AppState+SSH.swift, and an extension in another file can't see
    /// a private member.
    var mcpServer: MCPSocketServer?
    /// Started from AppState+Persistence.swift's launch path.
    var dashboardServer: DashboardServer?

    /// Create a new instance.
    public init() {
        self.windowIndex = WindowIndexPool.shared.claim()
        // Forward shared favorites store changes to this AppState's publisher
        // so SwiftUI views update when favorites change from any window
        favoritesCancellable = FavoritesStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
        // Forward shared appearance store changes so all windows update together
        appearanceCancellable = AppearanceStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
        // Forward topology store changes so SwiftUI views see staleness updates
        topologyCancellable = NetworkTopologyStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        WindowIndexPool.shared.release(windowIndex)
    }

    // MARK: - Host Helpers

    /// Host.
    public func host(for id: UUID) -> HostConfig? {
        hosts.first { $0.id == id }
    }

    /// Active host.
    public var activeHost: HostConfig? {
        if let session = activeSession {
            return host(for: session.source.hostID)
        }
        return hosts.first
    }

    /// The SSH config for the active host (convenience for monitor, file browser, etc.)
    public var activeSSHConfig: SSHConfig {
        activeHost?.ssh ?? SSHConfig()
    }

    /// Host for session.
    public func hostForSession(_ session: TmuxSession) -> HostConfig? {
        host(for: session.source.hostID)
    }

    /// Add host.
    public func addHost(_ host: HostConfig) {
        hosts.append(host)
        saveHosts()
    }

    /// Remove host.
    public func removeHost(_ hostID: UUID) {
        guard hostID != HostConfig.localhostID else { return }
        // Tear down SSH mux on background thread to avoid blocking UI
        if let host = hosts.first(where: { $0.id == hostID }) {
            DispatchQueue.global(qos: .utility).async { [self] in
                self.sshMuxStop(for: host)
            }
        }
        hosts.removeAll { $0.id == hostID }
        // Stop any language servers for this host (removeHost runs on the main thread).
        MainActor.assumeIsolated { lsp.shutdown(hostID: hostID) }
        // Remove sessions belonging to this host (and their connection state)
        let removedSessionIDs = Set(allSessions.filter { $0.source.hostID == hostID }.map { $0.id })
        sessionConnectionStates = sessionConnectionStates.filter { !removedSessionIDs.contains($0.key) }
        allSessions.removeAll { $0.source.hostID == hostID }
        favoriteEntries.removeAll { entry in
            allSessions.first(where: { $0.id == entry.sessionID }) == nil
        }
        // Clear key setup state if it was for the removed host
        if keySetupHostID == hostID {
            needsKeySetup = false
            keySetupInProgress = false
            keySetupHostID = nil
        }
        // If the active session belonged to this host, clear it
        if activeSession?.source.hostID == hostID {
            activeSession = nil
        }
        saveHosts()
        saveFavorites()
    }

    /// Update host.
    public func updateHost(_ host: HostConfig) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
            saveHosts()
        }
    }

    // MARK: - Session Helpers

    /// Active session name.
    public var activeSessionName: String {
        activeSession?.name ?? ""
    }

    /// Sessions grouped by host, then by source within each host.
    /// Docker logs sessions are merged into the same group as their container's docker sessions.
    /// Local sessions (browser, and future local types) are grouped under the
    /// localhost host entry — no special-casing by session type.
    public var hostGroupedSessions: [HostGroup] {
        var result: [HostGroup] = []
        for host in hosts {
            let hostSessions = allSessions.filter { $0.source.groupHostID == host.id }
            guard !hostSessions.isEmpty else {
                result.append(HostGroup(host: host, groups: []))
                continue
            }
            // Group by subGroupKey (container name for docker, stableKey for host, etc.)
            var groups: [String: [TmuxSession]] = [:]
            for s in hostSessions {
                groups[s.source.subGroupKey, default: []].append(s)
            }
            var sessionGroups: [SessionGroup] = []
            let hostKey = SessionSource.host(hostID: host.id).stableKey
            // Host sessions first
            if let sessions = groups[hostKey], !sessions.isEmpty {
                let sorted = sessions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                sessionGroups.append(SessionGroup(source: .host(hostID: host.id), sessions: sorted))
            }
            for (key, sessions) in groups.sorted(by: { $0.key < $1.key }) {
                if key != hostKey {
                    // Sort: regular tmux sessions alphabetically first, then utility sessions (logs, processes) at the end
                    let sorted = sessions.sorted { a, b in
                        if a.source.isUtility != b.source.isUtility { return !a.source.isUtility }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                    let groupSource = sorted.first(where: { !$0.source.isUtility })?.source ?? sorted[0].source
                    sessionGroups.append(SessionGroup(source: groupSource, sessions: sorted))
                }
            }
            result.append(HostGroup(host: host, groups: sessionGroups))
        }

        return result
    }

    /// All favorited session IDs (convenience for code that just needs the ID list)
    public var favoritedSessionIDs: [String] {
        favoriteEntries.map(\.sessionID)
    }

    // MARK: - Storage keys

    /// A session's note, under whichever key it happens to be stored.
    /// Write (or clear) a session's note.
    ///
    /// Writes the identity key and REMOVES every other spelling the note
    /// might be filed under. Without that second half, clearing a note
    /// stored under the legacy key silently did nothing: the write path
    /// cleared the identity key, the read path still found the legacy one,
    /// and the note came straight back. There was no way to get rid of it
    /// from the UI at all.
    ///
    /// Writes go through here rather than to the store directly — the
    /// store knows about keys, and only AppState knows which keys mean the
    /// same session.
    public func setNote(_ text: String, for session: TmuxSession) {
        let preferred = storageKey(for: session)
        SessionNotesStore.shared.setNote(text, for: preferred)
        for key in storageKeys(for: session) where key != preferred {
            SessionNotesStore.shared.clearNote(for: key)
        }
    }

    public func note(for session: TmuxSession) -> SessionNote? {
        for key in storageKeys(for: session) {
            if let note = SessionNotesStore.shared.note(for: key) { return note }
        }
        return nil
    }

    /// The key a session's note and favorite are stored under.
    ///
    /// Identity-based (`host:user@machine:name`) when we know which host
    /// the session belongs to, falling back to the in-memory id when we
    /// don't — a session on a host that's been deleted still has to
    /// resolve to something.
    public func storageKey(for session: TmuxSession) -> String {
        let hostID = session.source.hostID
        guard let host = hosts.first(where: { $0.id == hostID })
                ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil) else {
            return session.id
        }
        return SessionIdentity.storageKey(for: session, host: host)
    }

    /// Every key a session may be stored under, newest scheme first.
    ///
    /// The reader accepts BOTH forms, which is the whole point of doing
    /// this before any migration: an un-migrated file keeps working, a
    /// migrated one works, and a half-migrated one works too. Changing
    /// the stored format before the reader could do this is what made a
    /// favorites list vanish.
    public func storageKeys(for session: TmuxSession) -> [String] {
        let preferred = storageKey(for: session)
        return preferred == session.id ? [preferred] : [preferred, session.id]
    }

    /// Map every key a set of sessions could be stored under back to the
    /// session, for matching stored entries against live sessions.
    func sessionsByStorageKey(_ sessions: [TmuxSession]) -> [String: TmuxSession] {
        var map: [String: TmuxSession] = [:]
        for session in sessions {
            for key in storageKeys(for: session) where map[key] == nil {
                map[key] = session
            }
        }
        return map
    }

    /// Only favorited sessions visible in this window, ordered by position
    public var favoriteSessions: [TmuxSession] {
        let sessionMap = sessionsByStorageKey(allSessions)
        return Self.firstPerSession(favoriteEntries
            .filter { windowIndex > 3 || $0.windows.contains(windowIndex) }
            .compactMap { sessionMap[$0.sessionID] })
    }

    /// All favorited sessions regardless of window assignment
    public var allFavoriteSessions: [TmuxSession] {
        let sessionMap = sessionsByStorageKey(allSessions)
        return Self.firstPerSession(favoriteEntries.compactMap { sessionMap[$0.sessionID] })
    }

    /// Keep the first appearance of each session, drop later ones.
    ///
    /// Belt to `collapseDuplicateFavorites`' braces. Two stored entries
    /// naming one session get repaired on disk, but the bar must not draw
    /// it twice in the meantime — and ⌘1-9 index this list, so a duplicate
    /// silently costs a number as well as looking wrong.
    static func firstPerSession(_ sessions: [TmuxSession]) -> [TmuxSession] {
        var seen = Set<String>()
        return sessions.filter { seen.insert($0.id).inserted }
    }

    /// Docker container names for a specific host
    public func dockerContainerNames(forHost hostID: UUID) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in allSessions where s.source.hostID == hostID {
            if let name = s.source.containerName, seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result.sorted()
    }

    /// Toggle a session's favorite status for the current window.
    /// If the session is favorited in this window, remove this window.
    /// If that leaves no windows, remove the entry entirely.
    /// If not favorited at all, add it for this window.
    public func toggleFavorite(_ session: TmuxSession) {
        let keys = storageKeys(for: session)
        if let idx = favoriteEntries.firstIndex(where: { keys.contains($0.sessionID) }) {
            if favoriteEntries[idx].windows.contains(windowIndex) {
                favoriteEntries[idx].windows.remove(windowIndex)
                if favoriteEntries[idx].windows.isEmpty {
                    favoriteEntries.remove(at: idx)
                }
            } else {
                favoriteEntries[idx].windows.insert(windowIndex)
            }
        } else {
            favoriteEntries.append(FavoriteEntry(sessionID: storageKey(for: session),
                                                windows: [windowIndex]))
        }
        saveFavorites()
    }

    /// Give a newly created session a ⌘-number in this window, if one is
    /// free.
    ///
    /// Switching sessions by keyboard requires a favorite, and users were
    /// having to discover the favoriting system before they could switch
    /// at all — the feature that makes the app fast was gated behind a
    /// concept nobody had met yet. Now the first nine sessions in a window
    /// arrive with a number already on them, and favoriting only becomes
    /// something to think about once there are more sessions than keys.
    ///
    /// Counts VISIBLE favorites rather than stored entries, because
    /// that's what ⌘1–9 actually indexes: an entry whose host is
    /// unreachable isn't reachable by a number either, so it shouldn't
    /// hold a slot shut.
    ///
    /// Only ever adds. It never removes or reorders anything the user
    /// arranged deliberately.
    public func autoFavoriteNewSession(_ session: TmuxSession) {
        let keys = storageKeys(for: session)
        if let existing = favoriteEntries.first(where: { keys.contains($0.sessionID) }),
           windowIndex > 3 || existing.windows.contains(windowIndex) {
            return   // already reachable here
        }
        guard favoriteSessions.count < 9 else { return }

        if let idx = favoriteEntries.firstIndex(where: { keys.contains($0.sessionID) }) {
            favoriteEntries[idx].windows.insert(windowIndex)
        } else {
            favoriteEntries.append(FavoriteEntry(sessionID: storageKey(for: session),
                                                windows: [windowIndex]))
        }
        saveFavorites()
    }

    /// Is favorited.
    public func isFavorited(_ session: TmuxSession) -> Bool {
        let keys = storageKeys(for: session)
        return favoriteEntries.contains { keys.contains($0.sessionID) }
    }

    /// Toggle whether a favorite is visible in a specific window
    public func toggleFavoriteWindow(_ session: TmuxSession, windowIndex: Int) {
        let keys = storageKeys(for: session)
        guard let idx = favoriteEntries.firstIndex(where: { keys.contains($0.sessionID) })
        else { return }
        if favoriteEntries[idx].windows.contains(windowIndex) {
            favoriteEntries[idx].windows.remove(windowIndex)
        } else {
            favoriteEntries[idx].windows.insert(windowIndex)
        }
        saveFavorites()
    }

    /// Check if a favorite is visible in a specific window
    public func isFavoriteInWindow(_ session: TmuxSession, windowIndex: Int) -> Bool {
        let keys = storageKeys(for: session)
        guard let entry = favoriteEntries.first(where: { keys.contains($0.sessionID) })
        else { return false }
        return entry.windows.contains(windowIndex)
    }

    /// Parse a favorited session ID back into a TmuxSession.
    /// Format: "stableKey:sessionName" where stableKey is "host:UUID", "docker:UUID:container", etc.
    public func parseFavoriteID(_ id: String) -> TmuxSession? {
        // Split on ":" — the session name is everything after the source key
        // host:UUID:name → source = host(UUID), name = name
        // docker:UUID:container:name → source = docker(UUID, container), name = name
        // browser:url:name → source = browser(url), name = display name
        // dockerlogs:UUID:container:name → utility, skip
        // dockertop:UUID:container:name → utility, skip
        let parts = id.split(separator: ":", maxSplits: 10).map(String.init)
        guard parts.count >= 2 else { return nil }

        let kind = parts[0]

        switch kind {
        case "host":
            guard parts.count >= 3, let hostID = UUID(uuidString: parts[1]) else { return nil }
            let name = parts.dropFirst(2).joined(separator: ":")
            guard !name.isEmpty else { return nil }
            return TmuxSession(name: name, source: .host(hostID: hostID))
        case "docker":
            guard parts.count >= 4, let hostID = UUID(uuidString: parts[1]) else { return nil }
            let container = parts[2]
            let name = parts.dropFirst(3).joined(separator: ":")
            guard !name.isEmpty else { return nil }
            return TmuxSession(name: name, source: .docker(hostID: hostID, containerName: container))
        case "browser":
            // browser:url:name — the URL is everything between "browser:" and the last ":name"
            // Session ID format: "browser:URL:displayName"
            // We need to reconstruct the URL which may contain colons (e.g. https://...)
            // The stableKey is "browser:URL", and the session ID is "stableKey:name"
            // So: browser:https://github.com:github.com
            guard parts.count >= 3 else { return nil }
            // The URL starts at parts[1] and the session name is the last component after the stableKey
            // Since stableKey = "browser:URL" and id = "stableKey:name",
            // we need to find where the URL ends and name begins.
            // URL always contains "://" so the name is the last segment after the full URL.
            let afterBrowser = parts.dropFirst(1).joined(separator: ":")
            // The session ID is: "browser:" + url + ":" + name
            // The stableKey is: "browser:" + url
            // So afterBrowser = url + ":" + name
            // We need to split off the last ":" segment as the name, but the URL may contain ":"
            // Actually, from the code: id = "\(source.stableKey):\(name)" = "browser:\(url):\(name)"
            // Since URLs contain "://", we can find the name by looking at the last ":" after the URL
            // Simplest: the name is everything after the last ":"
            guard let lastColon = afterBrowser.lastIndex(of: ":") else { return nil }
            let url = String(afterBrowser[afterBrowser.startIndex..<lastColon])
            let name = String(afterBrowser[afterBrowser.index(after: lastColon)...])
            guard !url.isEmpty, !name.isEmpty else { return nil }
            return TmuxSession(name: name, source: .browser(url: url))
        default:
            // dockerlogs, dockertop — utility sessions don't need recreation
            return nil
        }
    }

    /// Move favorite.
    public func moveFavorite(from source: IndexSet, to destination: Int) {
        favoriteEntries.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    /// Move a favorite up or down by one *visible* position.
    ///
    /// The stored list also carries entries belonging to other windows and
    /// entries whose session isn't currently reachable — neither of which
    /// this window renders. Swapping with one of those moved the favorite
    /// in the file while nothing changed on screen, so the button read as
    /// broken and you had to click it repeatedly to crawl past rows you
    /// can't see. Skip straight to the nearest neighbor the user can
    /// actually see, which is also the one the ⌘N numbering counts.
    public func moveFavoriteByID(_ sessionID: String, direction: Int) {
        guard direction != 0 else { return }
        // Callers hand over a live session's id; the entry may be stored
        // under that or under the identity key, so match on either.
        let wanted = Set(allSessions.first(where: { $0.id == sessionID })
                            .map { storageKeys(for: $0) } ?? [sessionID])
        guard let fromIdx = favoriteEntries.firstIndex(where: { wanted.contains($0.sessionID) })
        else { return }
        // Visibility is also a storage-key question: an entry is visible
        // when some live session resolves to it.
        let visibleIDs = Set(favoriteSessions.flatMap { storageKeys(for: $0) })
        var toIdx = fromIdx + direction
        while toIdx >= 0, toIdx < favoriteEntries.count,
              !visibleIDs.contains(favoriteEntries[toIdx].sessionID) {
            toIdx += direction
        }
        guard toIdx >= 0, toIdx < favoriteEntries.count else { return }
        favoriteEntries.swapAt(fromIdx, toIdx)
        saveFavorites()
    }

    /// Switch to a session and get the overlays off it.
    ///
    /// Any deliberate pick — ⌘-number, ⇧⇥, the favorites bar, a monitor
    /// row, a row in the session list — means "show me that terminal", so
    /// whatever is covering it gets out of the way.
    ///
    /// The session list used to be the exception, on the theory that you
    /// might flip between several sessions in a row. Users reported the
    /// opposite: you pick one, and the list sitting over the terminal you
    /// just asked for is in the way. ⌘J reopens it.
    ///
    /// `dismissIfAlreadyActive: false` is for list rows where a click on the
    /// row you're already on is more likely a mis-aim than a request —
    /// closing the overlay under that click feels random.
    public func jumpToSession(_ session: TmuxSession,
                              dismissIfAlreadyActive: Bool = true) {
        let alreadyActive = activeSession?.id == session.id
        if !alreadyActive {
            switchToSession = session
        }
        guard !alreadyActive || dismissIfAlreadyActive else { return }
        showMonitor = false
        showSessionManager = false
    }

    // MARK: - Session administration

    /// Characters a new session name may contain.
    ///
    /// tmux forbids `.` and `:` in session names (they're the window and
    /// pane separators), and a name with those in it produces a session
    /// you can't target afterwards. Spaces are legal but make every
    /// `-t` awkward, so they're out too — this is deliberately narrower
    /// than tmux allows.
    public static func isValidSessionName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Single-quote for the remote shell. Existing session names can
    /// contain spaces (enumeration accepts them), so the OLD name always
    /// needs quoting even though new ones are restricted.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a tmux admin command for a session, on its own host or
    /// inside its container. Returns nil for sources that aren't tmux
    /// (browser tabs, docker logs/top) — there's nothing to rename.
    private func tmuxAdminCommand(_ args: String,
                                  for session: TmuxSession) -> (cmd: String, args: [String])? {
        switch session.source {
        case .host(let hostID):
            guard let host = hosts.first(where: { $0.id == hostID })
                    ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil) else { return nil }
            return remoteCommand("tmux \(args)", host: host)
        case .docker(let hostID, let containerName):
            guard let host = hosts.first(where: { $0.id == hostID }) else { return nil }
            let safe = sanitizedContainer(containerName)
            return remoteCommand("docker exec \(safe) tmux \(args)", host: host)
        case .dockerLogs, .dockerTop, .browser:
            return nil
        }
    }

    /// Rename a tmux session, carrying its note and favorite slot over.
    ///
    /// A session's identity is `source:name`, so renaming changes its id
    /// — the note and the ⌘-number slot are keyed by that id and would
    /// be orphaned by a rename that only touched the remote. Moving them
    /// is not optional politeness; without it the rename looks like it
    /// deleted your note.
    public func renameSession(_ session: TmuxSession, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespaces)
        guard Self.isValidSessionName(newName), newName != session.name,
              let (cmd, args) = tmuxAdminCommand(
                "rename-session -t \(Self.shellQuote(session.name)) \(Self.shellQuote(newName))",
                for: session)
        else { return }

        let renamed = TmuxSession(name: newName, source: session.source)
        let oldID = session.id
        let wasActive = activeSession?.id == oldID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RemoteExec.shared.run(cmd, args: args, stdin: nil,
                                               softTimeout: 10,
                                               captureStdout: true, captureStderr: true,
                                               label: "renameSession")
            let failure = (result.stderr + result.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.exit != 0 {
                    DiagnosticLog.shared.record(
                        "session", "rename failed: \(failure.isEmpty ? "exit \(result.exit)" : failure)",
                        failure: true)
                    return
                }
                self.migrateSessionIdentity(from: session, to: renamed)
                if wasActive { self.activeSession = renamed }
                self.refreshSessionList = true
            }
        }
    }

    /// Kill a tmux session and forget what was attached to it.
    public func killSession(_ session: TmuxSession) {
        guard let (cmd, args) = tmuxAdminCommand(
            "kill-session -t \(Self.shellQuote(session.name))", for: session) else { return }

        let id = session.id
        let wasActive = activeSession?.id == id
        // Move off it BEFORE it dies, so the terminal isn't sitting on a
        // session that no longer exists while the command runs.
        if wasActive, let next = allSessions.first(where: { $0.id != id && !$0.unavailable }) {
            switchToSession = next
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RemoteExec.shared.run(cmd, args: args, stdin: nil,
                                               softTimeout: 10,
                                               captureStdout: true, captureStderr: true,
                                               label: "killSession")
            let failure = (result.stderr + result.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.exit != 0 {
                    DiagnosticLog.shared.record(
                        "session", "kill failed: \(failure.isEmpty ? "exit \(result.exit)" : failure)",
                        failure: true)
                    return
                }
                self.forgetSessionEntries(session)
                self.refreshSessionList = true
            }
        }
    }

    /// Drop everything stored against a session that no longer exists.
    ///
    /// Separate from `killSession` so the local effect can be tested
    /// without a host to kill anything on — and so the two halves, "end
    /// it remotely" and "forget it locally", can't drift.
    func forgetSessionEntries(_ session: TmuxSession) {
        let keys = storageKeys(for: session)
        for key in keys { AlertStore.shared.forget(key: key) }
        for key in keys { SessionNotesStore.shared.clearNote(for: key) }
        FavoritesStore.shared.entries.removeAll { keys.contains($0.sessionID) }
        FavoritesStore.shared.save()
    }

    /// Move a session's note and favorite slot to its new name.
    ///
    /// Resolved through `storageKeys` on BOTH sides. The session's name is
    /// part of its storage key, so a rename changes that key — and an
    /// entry may still be sitting under the legacy id as well. Looking
    /// either side up by the in-memory id alone silently stopped carrying
    /// notes across a rename the moment storage moved to identity keys.
    func migrateSessionIdentity(from old: TmuxSession, to renamed: TmuxSession) {
        let oldKeys = storageKeys(for: old)
        let newKey = storageKey(for: renamed)

        for key in oldKeys {
            guard let note = SessionNotesStore.shared.note(for: key) else { continue }
            SessionNotesStore.shared.setNote(note.text, for: newKey)
            SessionNotesStore.shared.clearNote(for: key)
            break
        }
        var moved = false
        for i in FavoritesStore.shared.entries.indices
        where oldKeys.contains(FavoritesStore.shared.entries[i].sessionID) {
            // Edited in place so the ⌘-number keeps its position in the
            // bar — remove-and-append would silently renumber every
            // favorite after it.
            FavoritesStore.shared.entries[i].sessionID = newKey
            moved = true
        }
        if moved { FavoritesStore.shared.save() }
    }

    // MARK: - Window Title

    /// Effective window title.
    public var effectiveWindowTitle: String {
        var title = appearance.windowTitle
        if showMonitor {
            if let host = activeHost {
                title += " — \(host.label) — Monitoring"
            } else {
                title += " — Monitoring"
            }
        } else if let session = activeSession {
            title += " — \(session.displayLabel)"
        }
        return title
    }

    /// Dismiss top overlay.
    public func dismissTopOverlay() {
        if showWalkthrough {
            // Escape counts as "seen" — see WalkthroughOverlay.finish().
            showWalkthrough = false
            if !appearance.hasSeenWalkthrough {
                appearance.hasSeenWalkthrough = true
                saveAppearance()
            }
        } else if showHelp {
            showHelp = false
        } else if showPipelineAdder {
            showPipelineAdder = false
        } else if showSessionNoteEditor {
            showSessionNoteEditor = false
        } else if showCommandPalette {
            showCommandPalette = false
        } else if showWindowRename {
            showWindowRename = false
        } else if showSettings {
            showSettings = false
            saveAppearance()
        } else if showTerminalText {
            showTerminalText = false
            terminalTextContent = ""
        } else if showSessionManager {
            showSessionManager = false
        } else if showFilePreview {
            showFilePreview = false
        } else if showFullFileBrowser {
            showFullFileBrowser = false
        } else if showMonitor {
            showMonitor = false
        } else if activeRightPanel != nil {
            activeRightPanel = nil
        }
    }

    // MARK: - Claude Code Hooks Setup

    /// Progress line for an MCP install, shown as a toast. The work
    /// itself lives in AppState+MCPSetup.swift; the property stays here
    /// because an extension cannot hold stored state.
    @Published public var hooksSetupStatus: String?
}
