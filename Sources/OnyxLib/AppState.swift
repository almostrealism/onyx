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
    static let cycleTmuxSession = Notification.Name("cycleTmuxSession")
    static let createTmuxSession = Notification.Name("createTmuxSession")
    static let toggleSessionManager = Notification.Name("toggleSessionManager")
    static let switchToFavorite = Notification.Name("switchToFavorite")
    static let refreshSession = Notification.Name("refreshSession")
    static let toggleArtifacts = Notification.Name("toggleArtifacts")
    static let restoreTerminalFocus = Notification.Name("restoreTerminalFocus")
    static let refreshPoolStatus = Notification.Name("refreshPoolStatus")
    static let toggleMemoryChart = Notification.Name("toggleMemoryChart")
}

// MARK: - Favorite Entry

public struct FavoriteEntry: Codable, Equatable {
    public var sessionID: String
    /// Window indices (0-3) where this favorite is visible. Empty = visible nowhere.
    public var windows: Set<Int>

    public init(sessionID: String, windows: Set<Int> = [0]) {
        self.sessionID = sessionID
        self.windows = windows
    }
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

// MARK: - Shared Favorites Store

/// Singleton that owns the favorites data. All windows read/write through this
/// to avoid race conditions on the shared JSON file.
public class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public var entries: [FavoriteEntry] = []
    private var url: URL?
    private let lock = NSLock()

    private init() {}

    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return } // only configure once
        self.url = url
        load()
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        if let entries = try? JSONDecoder().decode([FavoriteEntry].self, from: data) {
            self.entries = entries
        } else if let ids = try? JSONDecoder().decode([String].self, from: data) {
            // Backward compatibility: old format was just [String]
            self.entries = ids.map { FavoriteEntry(sessionID: $0, windows: [0]) }
            save()
        }
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = url else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url)
        }
    }

    /// Reset for testing — clears all entries without saving
    public func reset() {
        lock.lock()
        entries = []
        lock.unlock()
    }
}

// MARK: - Focus Tracking

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
        if activeRightPanel != nil { return .rightPanel }
        return .terminal
    }

    /// Recalculate and set focusedComponent based on current visibility state.
    /// Call this when an overlay opens or closes to ensure correct precedence.
    public func recalculateFocus() {
        focusedComponent = topVisibleComponent
        if focusedComponent == .terminal {
            NotificationCenter.default.post(name: .restoreTerminalFocus, object: nil)
        }
    }
}

// MARK: - Right Panel

public enum RightPanel: Equatable {
    case notes
    case fileBrowser
    case artifacts
}

// MARK: - Host Config

public struct SSHConfig: Codable, Hashable {
    public var host: String = ""
    public var user: String = ""
    public var port: Int = 22
    public var tmuxSession: String = "onyx"
    public var identityFile: String = ""

    public init(host: String = "", user: String = "", port: Int = 22, tmuxSession: String = "onyx", identityFile: String = "") {
        self.host = host
        self.user = user
        self.port = port
        self.tmuxSession = tmuxSession
        self.identityFile = identityFile
    }
}

public struct HostConfig: Codable, Identifiable, Hashable {
    public var id: UUID
    public var label: String
    public var ssh: SSHConfig

    public init(id: UUID = UUID(), label: String, ssh: SSHConfig = SSHConfig()) {
        self.id = id
        self.label = label
        self.ssh = ssh
    }

    public var isLocal: Bool {
        let h = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.isEmpty
    }

    public static let localhostID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public static var localhost: HostConfig {
        HostConfig(id: localhostID, label: "localhost", ssh: SSHConfig())
    }
}

public struct AppearanceConfig: Codable {
    public var fontSize: Double = 13           // legacy, maps to terminalFontSize
    public var terminalFontSize: Double?        // nil = use fontSize for backward compat
    public var terminalFontName: String = "SF Mono"
    public var uiFontSize: Double = 12
    public var windowOpacity: Double = 0.82
    public var accentHex: String = "66CCFF"
    public var windowTitle: String = "Onyx"
    public var remindersList: String = ""  // empty = all lists

    public var effectiveTerminalFontSize: Double {
        terminalFontSize ?? fontSize
    }

    public static let accentOptions = ["66CCFF", "FF6B6B", "6BFF8E", "FFD06B", "C06BFF", "FF6BCD"]

    public static let terminalFontOptions = [
        "SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono",
        "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono",
        "Hack", "Inconsolata"
    ]

    public init(fontSize: Double = 13, windowOpacity: Double = 0.82, accentHex: String = "66CCFF", windowTitle: String = "Onyx", remindersList: String = "") {
        self.fontSize = fontSize
        self.windowOpacity = windowOpacity
        self.accentHex = accentHex
        self.windowTitle = windowTitle
        self.remindersList = remindersList
    }
}

// MARK: - Connection Pool Info

public struct ConnectionInfo: Identifiable {
    public let id: String           // session ID from pool
    public let label: String        // display name
    public let hostLabel: String    // host name
    public let isRunning: Bool      // process is alive
    public let isActive: Bool       // currently displayed terminal
    public let lastActiveTime: Date
    public let source: SessionSource?

    public var status: String {
        if isActive && isRunning { return "active" }
        if isRunning { return "connected" }
        return "disconnected"
    }

    public var statusColor: String {
        if isActive && isRunning { return "6BFF8E" }  // green
        if isRunning { return "FFD06B" }               // yellow
        return "FF6B6B"                                 // red
    }
}

// MARK: - Session Model

public enum SessionSource: Codable, Hashable {
    case host(hostID: UUID)
    case docker(hostID: UUID, containerName: String)
    case dockerLogs(hostID: UUID, containerName: String)
    case dockerTop(hostID: UUID, containerName: String)

    public var hostID: UUID {
        switch self {
        case .host(let id): return id
        case .docker(let id, _): return id
        case .dockerLogs(let id, _): return id
        case .dockerTop(let id, _): return id
        }
    }

    public var stableKey: String {
        switch self {
        case .host(let id): return "host:\(id.uuidString)"
        case .docker(let id, let name): return "docker:\(id.uuidString):\(name)"
        case .dockerLogs(let id, let name): return "dockerlogs:\(id.uuidString):\(name)"
        case .dockerTop(let id, let name): return "dockertop:\(id.uuidString):\(name)"
        }
    }

    public var displayName: String {
        switch self {
        case .host: return "Host"
        case .docker(_, let name): return name
        case .dockerLogs(_, let name): return "\(name) logs"
        case .dockerTop(_, let name): return "\(name) processes"
        }
    }

    public var isDocker: Bool {
        switch self {
        case .docker, .dockerLogs, .dockerTop: return true
        default: return false
        }
    }

    public var isDockerLogs: Bool {
        if case .dockerLogs = self { return true }
        return false
    }

    public var isDockerTop: Bool {
        if case .dockerTop = self { return true }
        return false
    }

    /// True for pseudo-sessions that are not interactive tmux sessions
    public var isUtility: Bool {
        isDockerLogs || isDockerTop
    }

    public var containerName: String? {
        switch self {
        case .docker(_, let name): return name
        case .dockerLogs(_, let name): return name
        case .dockerTop(_, let name): return name
        default: return nil
        }
    }
}

public struct TmuxSession: Identifiable, Hashable {
    public let name: String
    public let source: SessionSource
    public let unavailable: Bool

    public init(name: String, source: SessionSource, unavailable: Bool = false) {
        self.name = name
        self.source = source
        self.unavailable = unavailable
    }

    public var id: String { "\(source.stableKey):\(name)" }

    public var displayLabel: String {
        switch source {
        case .host: return name
        case .docker(_, let container): return "\(container)/\(name)"
        case .dockerLogs(_, let container): return "\(container)/logs"
        case .dockerTop(_, let container): return "\(container)/top"
        }
    }
}

public struct SessionGroup: Identifiable {
    public var id: String { source.stableKey }
    public let source: SessionSource
    public let sessions: [TmuxSession]
}

public struct HostGroup: Identifiable {
    public var id: UUID { host.id }
    public let host: HostConfig
    public let groups: [SessionGroup]
}

public class AppState: ObservableObject {
    @Published public var hosts: [HostConfig] = []
    @Published public var appearance = AppearanceConfig()
    @Published public var showSetup = false
    @Published public var activeRightPanel: RightPanel? = nil
    @Published public var showSettings = false
    @Published public var showCommandPalette = false
    @Published public var showMonitor = false
    @Published public var isReconnecting = false
    @Published public var reconnectRequested = false
    @Published public var refreshSessionList = false
    @Published public var createNoteRequested = false
    @Published public var showWindowRename = false
    @Published public var connectionError: String?
    @Published public var needsKeySetup = false
    @Published public var keySetupInProgress = false
    @Published public var showSessionManager = false
    public var showFocusOutline = true

    /// Tracks which component should logically have keyboard focus.
    /// Updated explicitly when overlays open/close and when the user clicks.
    @Published public var focusedComponent: FocusedComponent = .terminal

    // Convenience accessors for right panel types
    public var showNotes: Bool {
        get { activeRightPanel == .notes }
        set { activeRightPanel = newValue ? .notes : nil }
    }

    public var showFileBrowser: Bool {
        get { activeRightPanel == .fileBrowser }
        set { activeRightPanel = newValue ? .fileBrowser : nil }
    }

    public var showArtifacts: Bool {
        get { activeRightPanel == .artifacts }
        set { activeRightPanel = newValue ? .artifacts : nil }
    }
    @Published public var configLoaded = false

    // Session state
    @Published public var isEnumeratingSessions = false
    @Published public var connectionPool: [ConnectionInfo] = []
    @Published public var allSessions: [TmuxSession] = []
    @Published public var activeSession: TmuxSession?
    @Published public var switchToSession: TmuxSession?
    @Published public var createNewSession: TmuxSession?  // session to create, nil = none
    @Published public var showNewSessionPrompt = false
    /// Shared favorites store — all windows read/write through this singleton
    public var favoriteEntries: [FavoriteEntry] {
        get { FavoritesStore.shared.entries }
        set { FavoritesStore.shared.entries = newValue }
    }
    /// This window's index (0-3). Windows > 3 show all favorites.
    public let windowIndex: Int

    // Host being edited for key setup
    @Published public var keySetupHostID: UUID?

    private var monitorCancellable: AnyCancellable?
    private var favoritesCancellable: AnyCancellable?
    public lazy var monitor: MonitorManager = {
        let m = MonitorManager(appState: self)
        monitorCancellable = m.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return m
    }()

    private var artifactCancellable: AnyCancellable?
    public lazy var artifactManager: ArtifactManager = {
        let a = ArtifactManager()
        artifactCancellable = a.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return a
    }()

    private var mcpServer: MCPSocketServer?

    public init() {
        self.windowIndex = WindowIndexPool.shared.claim()
        // Forward shared favorites store changes to this AppState's publisher
        // so SwiftUI views update when favorites change from any window
        favoritesCancellable = FavoritesStore.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        WindowIndexPool.shared.release(windowIndex)
    }

    // MARK: - Host Helpers

    public func host(for id: UUID) -> HostConfig? {
        hosts.first { $0.id == id }
    }

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

    public func hostForSession(_ session: TmuxSession) -> HostConfig? {
        host(for: session.source.hostID)
    }

    public func addHost(_ host: HostConfig) {
        hosts.append(host)
        saveHosts()
    }

    public func removeHost(_ hostID: UUID) {
        guard hostID != HostConfig.localhostID else { return }
        hosts.removeAll { $0.id == hostID }
        // Remove sessions belonging to this host
        allSessions.removeAll { $0.source.hostID == hostID }
        favoriteEntries.removeAll { entry in
            allSessions.first(where: { $0.id == entry.sessionID }) == nil
        }
        // Clear key setup state if it was for the removed host
        if keySetupHostID == hostID {
            needsKeySetup = false
            keySetupInProgress = false
            keySetupHostID = nil
            connectionError = nil
        }
        // If the active session belonged to this host, clear it
        if activeSession?.source.hostID == hostID {
            activeSession = nil
        }
        saveHosts()
        saveFavorites()
    }

    public func updateHost(_ host: HostConfig) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
            saveHosts()
        }
    }

    // MARK: - Session Helpers

    public var activeSessionName: String {
        activeSession?.name ?? ""
    }

    /// Sessions grouped by host, then by source within each host.
    /// Docker logs sessions are merged into the same group as their container's docker sessions.
    public var hostGroupedSessions: [HostGroup] {
        var result: [HostGroup] = []
        for host in hosts {
            let hostSessions = allSessions.filter { $0.source.hostID == host.id }
            guard !hostSessions.isEmpty else {
                result.append(HostGroup(host: host, groups: []))
                continue
            }
            // Group by container name for docker/dockerLogs, by stableKey for host
            var groups: [String: [TmuxSession]] = [:]
            for s in hostSessions {
                let key: String
                switch s.source {
                case .host: key = SessionSource.host(hostID: host.id).stableKey
                case .docker(_, let name), .dockerLogs(_, let name), .dockerTop(_, let name):
                    key = SessionSource.docker(hostID: host.id, containerName: name).stableKey
                }
                groups[key, default: []].append(s)
            }
            var sessionGroups: [SessionGroup] = []
            let hostKey = SessionSource.host(hostID: host.id).stableKey
            if let sessions = groups[hostKey], !sessions.isEmpty {
                sessionGroups.append(SessionGroup(source: .host(hostID: host.id), sessions: sessions))
            }
            for (key, sessions) in groups.sorted(by: { $0.key < $1.key }) {
                if key != hostKey {
                    // Use the first docker (non-logs) source as the group source
                    let groupSource = sessions.first(where: { !$0.source.isUtility })?.source ?? sessions[0].source
                    sessionGroups.append(SessionGroup(source: groupSource, sessions: sessions))
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

    /// Only favorited sessions visible in this window, ordered by position
    public var favoriteSessions: [TmuxSession] {
        let sessionMap = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favoriteEntries
            .filter { windowIndex > 3 || $0.windows.contains(windowIndex) }
            .compactMap { sessionMap[$0.sessionID] }
    }

    /// All favorited sessions regardless of window assignment
    public var allFavoriteSessions: [TmuxSession] {
        let sessionMap = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favoriteEntries.compactMap { sessionMap[$0.sessionID] }
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
        if let idx = favoriteEntries.firstIndex(where: { $0.sessionID == session.id }) {
            if favoriteEntries[idx].windows.contains(windowIndex) {
                favoriteEntries[idx].windows.remove(windowIndex)
                if favoriteEntries[idx].windows.isEmpty {
                    favoriteEntries.remove(at: idx)
                }
            } else {
                favoriteEntries[idx].windows.insert(windowIndex)
            }
        } else {
            favoriteEntries.append(FavoriteEntry(sessionID: session.id, windows: [windowIndex]))
        }
        saveFavorites()
    }

    public func isFavorited(_ session: TmuxSession) -> Bool {
        favoriteEntries.contains { $0.sessionID == session.id }
    }

    /// Toggle whether a favorite is visible in a specific window
    public func toggleFavoriteWindow(_ session: TmuxSession, windowIndex: Int) {
        guard let idx = favoriteEntries.firstIndex(where: { $0.sessionID == session.id }) else { return }
        if favoriteEntries[idx].windows.contains(windowIndex) {
            favoriteEntries[idx].windows.remove(windowIndex)
        } else {
            favoriteEntries[idx].windows.insert(windowIndex)
        }
        saveFavorites()
    }

    /// Check if a favorite is visible in a specific window
    public func isFavoriteInWindow(_ session: TmuxSession, windowIndex: Int) -> Bool {
        guard let entry = favoriteEntries.first(where: { $0.sessionID == session.id }) else { return false }
        return entry.windows.contains(windowIndex)
    }

    /// Parse a favorited session ID back into a TmuxSession.
    /// Format: "stableKey:sessionName" where stableKey is "host:UUID", "docker:UUID:container", etc.
    public func parseFavoriteID(_ id: String) -> TmuxSession? {
        // Split on ":" — the session name is everything after the source key
        // host:UUID:name → source = host(UUID), name = name
        // docker:UUID:container:name → source = docker(UUID, container), name = name
        // dockerlogs:UUID:container:name → utility, skip
        // dockertop:UUID:container:name → utility, skip
        let parts = id.split(separator: ":", maxSplits: 10).map(String.init)
        guard parts.count >= 3 else { return nil }

        let kind = parts[0]
        guard let hostID = UUID(uuidString: parts[1]) else { return nil }

        switch kind {
        case "host":
            // host:UUID:sessionName
            let name = parts.dropFirst(2).joined(separator: ":")
            guard !name.isEmpty else { return nil }
            return TmuxSession(name: name, source: .host(hostID: hostID))
        case "docker":
            // docker:UUID:containerName:sessionName
            guard parts.count >= 4 else { return nil }
            let container = parts[2]
            let name = parts.dropFirst(3).joined(separator: ":")
            guard !name.isEmpty else { return nil }
            return TmuxSession(name: name, source: .docker(hostID: hostID, containerName: container))
        default:
            // dockerlogs, dockertop — utility sessions don't need recreation
            return nil
        }
    }

    public func moveFavorite(from source: IndexSet, to destination: Int) {
        favoriteEntries.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    /// Move a favorite up or down within the full entries list by session ID
    public func moveFavoriteByID(_ sessionID: String, direction: Int) {
        guard let fromIdx = favoriteEntries.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        let toIdx = fromIdx + direction
        guard toIdx >= 0 && toIdx < favoriteEntries.count else { return }
        favoriteEntries.swapAt(fromIdx, toIdx)
        saveFavorites()
    }

    // MARK: - Window Title

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

    // MARK: - Persistence

    private var appSupportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Onyx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var hostsURL: URL {
        appSupportDir.appendingPathComponent("hosts.json")
    }

    private var legacyConfigURL: URL {
        appSupportDir.appendingPathComponent("config.json")
    }

    private var appearanceURL: URL {
        appSupportDir.appendingPathComponent("appearance.json")
    }

    private var favoritesURL: URL {
        appSupportDir.appendingPathComponent("favorites.json")
    }

    public var notesDirectory: URL {
        let dir = appSupportDir.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public lazy var notesManager: NotesManager = {
        NotesManager(directory: notesDirectory)
    }()

    public lazy var fileBrowserManager: FileBrowserManager = {
        FileBrowserManager(appState: self)
    }()

    public var savedFoldersURL: URL {
        appSupportDir.appendingPathComponent("folders.json")
    }

    public var accentColor: Color {
        Color(hex: appearance.accentHex)
    }

    /// Scale factor for UI text relative to default size of 12
    public var uiScale: CGFloat {
        CGFloat(appearance.uiFontSize / 12.0)
    }

    /// Scaled UI font size — multiply a base size by the UI scale factor
    public func uiSize(_ base: CGFloat) -> CGFloat {
        (base * uiScale).rounded()
    }

    public func loadConfig() {
        // Try loading multi-host config
        if FileManager.default.fileExists(atPath: hostsURL.path) {
            if let data = try? Data(contentsOf: hostsURL),
               let loaded = try? JSONDecoder().decode([HostConfig].self, from: data) {
                hosts = loaded
            }
        } else if FileManager.default.fileExists(atPath: legacyConfigURL.path) {
            // Migrate from single-host config
            if let data = try? Data(contentsOf: legacyConfigURL),
               let sshConfig = try? JSONDecoder().decode(SSHConfig.self, from: data) {
                let label = sshConfig.host.isEmpty ? "localhost" : sshConfig.host
                let migrated = HostConfig(id: UUID(), label: label, ssh: sshConfig)
                hosts = [migrated]
            }
        }

        // Ensure localhost is always present
        if !hosts.contains(where: { $0.id == HostConfig.localhostID }) {
            hosts.insert(.localhost, at: 0)
        }

        // If we only have localhost, show setup to add a remote host
        if hosts.count <= 1 && !FileManager.default.fileExists(atPath: hostsURL.path) && !FileManager.default.fileExists(atPath: legacyConfigURL.path) {
            showSetup = true
        }

        saveHosts()

        if FileManager.default.fileExists(atPath: appearanceURL.path) {
            if let data = try? Data(contentsOf: appearanceURL),
               let config = try? JSONDecoder().decode(AppearanceConfig.self, from: data) {
                appearance = config
            }
        }

        loadFavorites()
        configLoaded = true

        // Start background monitoring immediately
        monitor.startPolling()

        // Start MCP socket server for agent integration
        mcpServer = MCPSocketServer(artifactManager: artifactManager)
        mcpServer?.start()
    }

    public func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: hostsURL)
        }
    }

    /// Legacy compat: called by SetupView after first host is configured
    public func saveConfig() {
        saveHosts()
        showSetup = false
    }

    public func saveAppearance() {
        if let data = try? JSONEncoder().encode(appearance) {
            try? data.write(to: appearanceURL)
        }
    }

    private func loadFavorites() {
        FavoritesStore.shared.configure(url: favoritesURL)
    }

    private func saveFavorites() {
        FavoritesStore.shared.save()
    }

    public func dismissTopOverlay() {
        if showCommandPalette {
            showCommandPalette = false
        } else if showWindowRename {
            showWindowRename = false
        } else if showSettings {
            showSettings = false
        } else if showSessionManager {
            showSessionManager = false
        } else if showMonitor {
            showMonitor = false
        } else if activeRightPanel != nil {
            activeRightPanel = nil
        }
    }

    // MARK: - Command Builders

    /// Extra PATH entries so tmux/docker are found even when login profile doesn't set it
    let extraPath = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/snap/bin\""

    /// Run a shell command on a host and return (executable, args)
    public func remoteCommand(_ script: String, host: HostConfig? = nil) -> (String, [String]) {
        let h = host ?? activeHost ?? .localhost
        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) \(script)"])
        }

        var args = [String]()
        args.append("-o"); args.append("BatchMode=yes")
        args.append("-o"); args.append("ConnectTimeout=5")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if h.ssh.port != 22 {
            args.append("-p"); args.append("\(h.ssh.port)")
        }
        if !h.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(h.ssh.identityFile)
        }
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) \(script)'")
        return ("/usr/bin/ssh", args)
    }

    /// Sanitize a session name for safe shell interpolation
    func sanitizedSession(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    /// Sanitize a container name for safe shell interpolation
    func sanitizedContainer(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    /// SSH flags and env export for MCP remote port forwarding.
    /// Uses `-o ExitOnForwardFailure=no` so the session always connects even if the port is busy.
    private func mcpForwardingArgs() -> (sshFlags: [String], envExport: String) {
        guard let localPort = mcpServer?.tcpPort else { return ([], "") }
        let remotePort = MCPSocketServer.defaultRemotePort
        return (
            ["-o", "ExitOnForwardFailure=no", "-R", "\(remotePort):127.0.0.1:\(localPort)"],
            "export ONYX_MCP_PORT=\(remotePort); tmux set-environment ONYX_MCP_PORT \(remotePort) 2>/dev/null; "
        )
    }

    /// Kill stale MCP port listeners on a remote host before connecting.
    /// Call this before establishing an SSH session with `-R` forwarding.
    /// Fire-and-forget cleanup of stale MCP port listeners on a remote host.
    /// Runs asynchronously to avoid blocking the main thread (SSH may hang if
    /// the network is asleep, e.g. when the screen saver activates).
    public func cleanupRemoteMCPPort(host h: HostConfig) {
        guard !h.isLocal, mcpServer?.tcpPort != nil else { return }
        let remotePort = MCPSocketServer.defaultRemotePort
        let (cmd, args) = remoteCommand("lsof -ti tcp:\(remotePort) 2>/dev/null | xargs kill 2>/dev/null", host: h)
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 5)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()

            try? process.run()
            process.waitUntilExit()
            killTimer.cancel()
        }
    }

    /// Build the command for a session based on its source
    public func commandForSession(_ session: TmuxSession) -> (String, [String]) {
        let h = host(for: session.source.hostID) ?? .localhost
        switch session.source {
        case .host:
            return sshCommand(host: h, sessionName: session.name)
        case .docker(_, let containerName):
            return dockerTmuxCommand(host: h, container: containerName, sessionName: session.name)
        case .dockerLogs(_, let containerName):
            return dockerLogsCommand(host: h, container: containerName)
        case .dockerTop(_, let containerName):
            return dockerTopCommand(host: h, container: containerName)
        }
    }

    /// Build the command to stream docker container logs (read-only)
    public func dockerLogsCommand(host h: HostConfig, container: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let dockerCmd = "docker logs -f --tail 1000 \(safeContainer)"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", dockerCmd])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if h.ssh.port != 22 {
            args.append("-p"); args.append("\(h.ssh.port)")
        }
        if !h.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(h.ssh.identityFile)
        }
        args.append("-t")
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to show docker container processes (refreshes every 2s)
    public func dockerTopCommand(host h: HostConfig, container: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let dockerCmd = "while true; do clear; date; echo; docker top \(safeContainer) -eo pid,user,%cpu,%mem,etime,comm 2>&1; sleep 2; done"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", dockerCmd])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if h.ssh.port != 22 {
            args.append("-p"); args.append("\(h.ssh.port)")
        }
        if !h.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(h.ssh.identityFile)
        }
        args.append("-t")
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command for a host tmux session
    public func sshCommand(host h: HostConfig, sessionName: String) -> (String, [String]) {
        let sess = sanitizedSession(sessionName)

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) tmux new-session -A -s \(sess)"])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if h.ssh.port != 22 {
            args.append("-p"); args.append("\(h.ssh.port)")
        }
        if !h.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(h.ssh.identityFile)
        }
        // MCP remote port forwarding — allows remote agents to talk back to Onyx
        let mcpArgs = mcpForwardingArgs()
        args.append(contentsOf: mcpArgs.sshFlags)
        args.append("-t")
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(mcpArgs.envExport)\(extraPath) tmux new-session -A -s \(sess)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to attach to a tmux session inside a docker container
    public func dockerTmuxCommand(host h: HostConfig, container: String, sessionName: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let safeSess = sanitizedSession(sessionName)
        let dockerCmd = "docker exec -it \(safeContainer) tmux new-session -A -s \(safeSess)"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) \(dockerCmd)"])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if h.ssh.port != 22 {
            args.append("-p"); args.append("\(h.ssh.port)")
        }
        if !h.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(h.ssh.identityFile)
        }
        // MCP remote port forwarding
        let mcpArgs = mcpForwardingArgs()
        args.append(contentsOf: mcpArgs.sshFlags)
        args.append("-t")
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(mcpArgs.envExport)\(extraPath) \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command + args to run a one-off stats collection
    public func statsCommand(host h: HostConfig? = nil) -> (String, [String]) {
        let host = h ?? activeHost ?? .localhost
        let statsScript = """
        echo "---UPTIME---"; uptime; \
        echo "---CPU---"; CPU_OUT=$(top -bn1 2>/dev/null | head -5); \
        if [ -n "$CPU_OUT" ]; then echo "$CPU_OUT"; else top -l1 -s0 2>/dev/null | head -10; fi; \
        echo "---MEM---"; MEM_OUT=$(free -m 2>/dev/null); \
        if [ -n "$MEM_OUT" ]; then echo "$MEM_OUT"; else vm_stat 2>/dev/null; fi; \
        echo "---GPU---"; nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,name --format=csv,noheader 2>/dev/null || \
        { GPU_PCT=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2); \
        [ -n "$GPU_PCT" ] && echo "AGX,$GPU_PCT" || echo "N/A"; }
        """

        if host.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", statsScript])
        }

        var args = [String]()
        args.append("-o"); args.append("BatchMode=yes")
        args.append("-o"); args.append("ConnectTimeout=5")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if host.ssh.port != 22 {
            args.append("-p"); args.append("\(host.ssh.port)")
        }
        if !host.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(host.ssh.identityFile)
        }
        let userHost = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(statsScript)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build a shell command that generates a key (if needed) and runs ssh-copy-id
    public func keySetupCommand(host h: HostConfig) -> (String, [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        var portFlag = ""
        if h.ssh.port != 22 {
            portFlag = "-p \(h.ssh.port) "
        }
        var identityFlag = ""
        var keyPath = "~/.ssh/id_ed25519"
        if !h.ssh.identityFile.isEmpty {
            keyPath = h.ssh.identityFile
            identityFlag = "-i \(h.ssh.identityFile) "
        }

        let sessName = sanitizedSession(activeSession?.name ?? h.ssh.tmuxSession)

        let script = """
        echo ""; \
        echo "╔══════════════════════════════════════════╗"; \
        echo "║        ONYX SSH KEY SETUP                ║"; \
        echo "╚══════════════════════════════════════════╝"; \
        echo ""; \
        KEY="\(keyPath)"; \
        KEY=$(eval echo "$KEY"); \
        if [ ! -f "$KEY" ]; then \
            echo "→ No SSH key found at $KEY"; \
            echo "→ Generating a new ed25519 key..."; \
            echo ""; \
            ssh-keygen -t ed25519 -f "$KEY" -N "" || exit 1; \
            echo ""; \
            echo "✓ Key generated."; \
        else \
            echo "✓ Found existing key: $KEY"; \
        fi; \
        echo ""; \
        echo "→ Installing key on \(userHost)..."; \
        echo "  You will be asked for your password ONE TIME."; \
        echo ""; \
        ssh-copy-id \(identityFlag)\(portFlag)\(userHost); \
        if [ $? -eq 0 ]; then \
            echo ""; \
            echo "✓ Key installed successfully!"; \
            echo "→ Connecting..."; \
            echo ""; \
            sleep 1; \
            exec ssh \(portFlag)\(identityFlag)-t -o StrictHostKeyChecking=accept-new \(userHost) \
                "exec \\$SHELL -lc '\(extraPath) tmux new-session -A -s \(sessName)'"; \
        else \
            echo ""; \
            echo "✗ Key installation failed."; \
            echo "  Check the password and try again."; \
            exit 1; \
        fi
        """
        return (shell, ["-lc", script])
    }
}
