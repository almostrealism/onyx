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

    public static let accentOptions = ["66CCFF", "FF6B6B", "6BFF8E", "FFD06B", "C06BFF", "FF6BCD"]

    public init(fontSize: Double = 13, windowOpacity: Double = 0.82, accentHex: String = "66CCFF", windowTitle: String = "Onyx") {
        self.fontSize = fontSize
        self.windowOpacity = windowOpacity
        self.accentHex = accentHex
        self.windowTitle = windowTitle
    }
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
    @Published public var tmuxSessions: [String] = []
    @Published public var activeSession: String = ""
    @Published public var switchToSession: String?
    @Published public var createNewSession = false

    private var monitorCancellable: AnyCancellable?
    public lazy var monitor: MonitorManager = {
        let m = MonitorManager(appState: self)
        monitorCancellable = m.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return m
    }()

    public init() {}

    /// The effective window title, incorporating session name and monitoring state
    public var effectiveWindowTitle: String {
        var title = appearance.windowTitle
        if !activeSession.isEmpty {
            title += " — \(activeSession)"
        }
        if showMonitor {
            title += " — Monitoring"
        }
        return title
    }

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

    public func dismissTopOverlay() {
        if showCommandPalette {
            showCommandPalette = false
        } else if showWindowRename {
            showWindowRename = false
        } else if showSettings {
            showSettings = false
        } else if showFileBrowser {
            showFileBrowser = false
        } else if showMonitor {
            showMonitor = false
        } else if showNotes {
            showNotes = false
        }
    }

    /// Run a shell command on the remote (or locally) and return stdout
    public func remoteCommand(_ script: String) -> (String, [String]) {
        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", script])
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
        args.append("exec $SHELL -lc '\(script)'")
        return ("/usr/bin/ssh", args)
    }

    /// Sanitize a session name for safe shell interpolation:
    /// replace any character that isn't alphanumeric, dash, or underscore with `_`.
    private func sanitizedSession(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    public var isLocal: Bool {
        let h = sshConfig.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.isEmpty
    }

    /// Build the command for the terminal session
    public func sshCommand(session: String? = nil) -> (String, [String]) {
        let rawSess = session ?? (activeSession.isEmpty ? sshConfig.tmuxSession : activeSession)
        let sess = sanitizedSession(rawSess)

        // Local: skip SSH, just run tmux directly
        if isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "tmux new-session -A -s \(sess)"])
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
        args.append("exec $SHELL -lc 'tmux new-session -A -s \(sess)'")
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

    /// Build a shell command that generates a key (if needed) and runs ssh-copy-id,
    /// then connects normally on success. Runs in the terminal so the user can type their password.
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

        // Script: check for key, generate if missing, then ssh-copy-id, then signal success
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
                "exec \\$SHELL -lc 'tmux new-session -A -s \(sanitizedSession(activeSession.isEmpty ? sshConfig.tmuxSession : activeSession))'"; \
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
