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
}

public struct SSHConfig: Codable {
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

public struct AppearanceConfig: Codable {
    public var fontSize: Double = 13
    public var windowOpacity: Double = 0.82
    public var accentHex: String = "66CCFF"
    public var windowTitle: String = "Onyx"
    public var remindersList: String = ""  // empty = all lists

    public static let accentOptions = ["66CCFF", "FF6B6B", "6BFF8E", "FFD06B", "C06BFF", "FF6BCD"]

    public init(fontSize: Double = 13, windowOpacity: Double = 0.82, accentHex: String = "66CCFF", windowTitle: String = "Onyx", remindersList: String = "") {
        self.fontSize = fontSize
        self.windowOpacity = windowOpacity
        self.accentHex = accentHex
        self.windowTitle = windowTitle
        self.remindersList = remindersList
    }
}

// MARK: - Session Model

public enum SessionSource: Codable, Hashable {
    case host
    case docker(containerName: String)

    public var stableKey: String {
        switch self {
        case .host: return "host"
        case .docker(let name): return "docker:\(name)"
        }
    }

    public var displayName: String {
        switch self {
        case .host: return "Host"
        case .docker(let name): return name
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
        case .docker(let container): return "\(container)/\(name)"
        }
    }
}

public struct SessionGroup: Identifiable {
    public var id: String { source.stableKey }
    public let source: SessionSource
    public let sessions: [TmuxSession]
}

public class AppState: ObservableObject {
    @Published public var sshConfig = SSHConfig()
    @Published public var appearance = AppearanceConfig()
    @Published public var showSetup = false
    @Published public var showNotes = false
    @Published public var showSettings = false
    @Published public var showCommandPalette = false
    @Published public var showMonitor = false
    @Published public var isReconnecting = false
    @Published public var reconnectRequested = false
    @Published public var createNoteRequested = false
    @Published public var showWindowRename = false
    @Published public var connectionError: String?
    @Published public var needsKeySetup = false
    @Published public var keySetupInProgress = false
    @Published public var showFileBrowser = false
    @Published public var showSessionManager = false
    @Published public var configLoaded = false

    // Session state
    @Published public var allSessions: [TmuxSession] = []
    @Published public var activeSession: TmuxSession?
    @Published public var switchToSession: TmuxSession?
    @Published public var createNewSession: TmuxSession?  // session to create, nil = none
    @Published public var showNewSessionPrompt = false
    @Published public var favoritedSessionIDs: [String] = []  // ordered list

    private var monitorCancellable: AnyCancellable?
    public lazy var monitor: MonitorManager = {
        let m = MonitorManager(appState: self)
        monitorCancellable = m.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return m
    }()

    public init() {}

    // MARK: - Session Helpers

    public var activeSessionName: String {
        activeSession?.name ?? ""
    }

    /// Sessions grouped by source for the session manager overlay
    public var groupedSessions: [SessionGroup] {
        var groups: [String: [TmuxSession]] = [:]
        for s in allSessions {
            groups[s.source.stableKey, default: []].append(s)
        }
        var result: [SessionGroup] = []
        // Host group first
        if let hostSessions = groups["host"], !hostSessions.isEmpty {
            result.append(SessionGroup(source: .host, sessions: hostSessions))
        }
        // Docker groups sorted by container name
        for (key, sessions) in groups.sorted(by: { $0.key < $1.key }) {
            if key != "host" {
                result.append(SessionGroup(source: sessions[0].source, sessions: sessions))
            }
        }
        return result
    }

    /// Only favorited sessions, ordered by their position in favoritedSessionIDs
    public var favoriteSessions: [TmuxSession] {
        let sessionMap = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favoritedSessionIDs.compactMap { sessionMap[$0] }
    }

    /// Host-only session names (backward compat for createNewTmuxSession naming)
    public var hostSessionNames: [String] {
        allSessions.filter { $0.source == .host }.map(\.name)
    }

    /// Unique docker container names from discovered sessions
    public var dockerContainerNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for s in allSessions {
            if case .docker(let name) = s.source, seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result.sorted()
    }

    public func toggleFavorite(_ session: TmuxSession) {
        if let idx = favoritedSessionIDs.firstIndex(of: session.id) {
            favoritedSessionIDs.remove(at: idx)
        } else {
            favoritedSessionIDs.append(session.id)
        }
        saveFavorites()
    }

    public func isFavorited(_ session: TmuxSession) -> Bool {
        favoritedSessionIDs.contains(session.id)
    }

    public func moveFavorite(from source: IndexSet, to destination: Int) {
        favoritedSessionIDs.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    // MARK: - Window Title

    public var effectiveWindowTitle: String {
        var title = appearance.windowTitle
        if let session = activeSession {
            title += " — \(session.displayLabel)"
        }
        if showMonitor {
            title += " — Monitoring"
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

    private var configURL: URL {
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

    public var savedFoldersURL: URL {
        appSupportDir.appendingPathComponent("folders.json")
    }

    public var accentColor: Color {
        Color(hex: appearance.accentHex)
    }

    public func loadConfig() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                sshConfig = try JSONDecoder().decode(SSHConfig.self, from: data)
            } catch {
                showSetup = true
            }
        } else {
            showSetup = true
        }

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
    }

    public func saveConfig() {
        do {
            let data = try JSONEncoder().encode(sshConfig)
            try data.write(to: configURL)
            showSetup = false
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    public func saveAppearance() {
        if let data = try? JSONEncoder().encode(appearance) {
            try? data.write(to: appearanceURL)
        }
    }

    private func loadFavorites() {
        if let data = try? Data(contentsOf: favoritesURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            favoritedSessionIDs = ids
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favoritedSessionIDs) {
            try? data.write(to: favoritesURL)
        }
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
        } else if showFileBrowser {
            showFileBrowser = false
        } else if showMonitor {
            showMonitor = false
        } else if showNotes {
            showNotes = false
        }
    }

    // MARK: - Command Builders

    /// Run a shell command on the remote (or locally) and return stdout
    public func remoteCommand(_ script: String) -> (String, [String]) {
        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) \(script)"])
        }

        var args = [String]()
        args.append("-o"); args.append("BatchMode=yes")
        args.append("-o"); args.append("ConnectTimeout=5")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if sshConfig.port != 22 {
            args.append("-p"); args.append("\(sshConfig.port)")
        }
        if !sshConfig.identityFile.isEmpty {
            args.append("-i"); args.append(sshConfig.identityFile)
        }
        let userHost = sshConfig.user.isEmpty ? sshConfig.host : "\(sshConfig.user)@\(sshConfig.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) \(script)'")
        return ("/usr/bin/ssh", args)
    }

    /// Extra PATH entries so tmux/docker are found even when login profile doesn't set it
    let extraPath = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/snap/bin\""

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

    public var isLocal: Bool {
        let h = sshConfig.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.isEmpty
    }

    /// Build the command for a session based on its source
    public func commandForSession(_ session: TmuxSession) -> (String, [String]) {
        switch session.source {
        case .host:
            return sshCommand(sessionName: session.name)
        case .docker(let containerName):
            return dockerTmuxCommand(container: containerName, sessionName: session.name)
        }
    }

    /// Build the command for a host tmux session
    public func sshCommand(sessionName: String? = nil) -> (String, [String]) {
        let rawSess = sessionName ?? (activeSession?.name ?? sshConfig.tmuxSession)
        let sess = sanitizedSession(rawSess)

        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) tmux new-session -A -s \(sess)"])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if sshConfig.port != 22 {
            args.append("-p"); args.append("\(sshConfig.port)")
        }
        if !sshConfig.identityFile.isEmpty {
            args.append("-i"); args.append(sshConfig.identityFile)
        }
        args.append("-t")
        let userHost = sshConfig.user.isEmpty ? sshConfig.host : "\(sshConfig.user)@\(sshConfig.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) tmux new-session -A -s \(sess)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to attach to a tmux session inside a docker container
    public func dockerTmuxCommand(container: String, sessionName: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let safeSess = sanitizedSession(sessionName)
        let dockerCmd = "docker exec -it \(safeContainer) tmux new-session -A -s \(safeSess)"

        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "\(extraPath) \(dockerCmd)"])
        }

        var args = [String]()
        args.append("-o"); args.append("ServerAliveInterval=10")
        args.append("-o"); args.append("ServerAliveCountMax=3")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if sshConfig.port != 22 {
            args.append("-p"); args.append("\(sshConfig.port)")
        }
        if !sshConfig.identityFile.isEmpty {
            args.append("-i"); args.append(sshConfig.identityFile)
        }
        args.append("-t")
        let userHost = sshConfig.user.isEmpty ? sshConfig.host : "\(sshConfig.user)@\(sshConfig.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(extraPath) \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command + args to run a one-off stats collection
    public func statsCommand() -> (String, [String]) {
        let statsScript = """
        echo "---UPTIME---"; uptime; \
        echo "---CPU---"; CPU_OUT=$(top -bn1 2>/dev/null | head -5); \
        if [ -n "$CPU_OUT" ]; then echo "$CPU_OUT"; else top -l1 -s0 2>/dev/null | head -10; fi; \
        echo "---MEM---"; MEM_OUT=$(free -m 2>/dev/null); \
        if [ -n "$MEM_OUT" ]; then echo "$MEM_OUT"; else vm_stat 2>/dev/null; fi; \
        echo "---GPU---"; nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,name --format=csv,noheader 2>/dev/null || echo "N/A"
        """

        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", statsScript])
        }

        var args = [String]()
        args.append("-o"); args.append("BatchMode=yes")
        args.append("-o"); args.append("ConnectTimeout=5")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if sshConfig.port != 22 {
            args.append("-p"); args.append("\(sshConfig.port)")
        }
        if !sshConfig.identityFile.isEmpty {
            args.append("-i"); args.append(sshConfig.identityFile)
        }
        let userHost = sshConfig.user.isEmpty ? sshConfig.host : "\(sshConfig.user)@\(sshConfig.host)"
        args.append(userHost)
        args.append("exec $SHELL -lc '\(statsScript)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build a shell command that generates a key (if needed) and runs ssh-copy-id
    public func keySetupCommand() -> (String, [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let userHost = sshConfig.user.isEmpty ? sshConfig.host : "\(sshConfig.user)@\(sshConfig.host)"
        var portFlag = ""
        if sshConfig.port != 22 {
            portFlag = "-p \(sshConfig.port) "
        }
        var identityFlag = ""
        var keyPath = "~/.ssh/id_ed25519"
        if !sshConfig.identityFile.isEmpty {
            keyPath = sshConfig.identityFile
            identityFlag = "-i \(sshConfig.identityFile) "
        }

        let sessName = sanitizedSession(activeSession?.name ?? sshConfig.tmuxSession)

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
