import Foundation

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
    /// Per-window accent color overrides. Key = window index (0-3), value = hex color.
    /// Windows without an entry use the global accentHex.
    public var windowAccents: [Int: String] = [:]
    public var windowTitle: String = "Onyx"
    public var remindersList: String?       // deprecated: migrated to remindersLists
    public var remindersLists: [String] = [] // empty = "Today" mode
    /// Last active session ID per window index, for session restore on startup
    public var lastSessionByWindow: [Int: String] = [:]
    /// Up to 3 additional timezone identifiers for monitor clocks (e.g., "America/New_York")
    public var extraTimezones: [String] = []
    /// Whether to use 12-hour (AM/PM) format for clocks (UTC always stays 24hr)
    public var use12HourClock: Bool = false

    public var effectiveTerminalFontSize: Double {
        terminalFontSize ?? fontSize
    }

    public static let accentOptions = ["66CCFF", "FF6B6B", "6BFF8E", "FFD06B", "C06BFF", "FF6BCD"]

    public static let terminalFontOptions = [
        "SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono",
        "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono",
        "Hack", "Inconsolata"
    ]

    public init(fontSize: Double = 13, windowOpacity: Double = 0.82, accentHex: String = "66CCFF", windowTitle: String = "Onyx", remindersLists: [String] = []) {
        self.fontSize = fontSize
        self.windowOpacity = windowOpacity
        self.accentHex = accentHex
        self.windowTitle = windowTitle
        self.remindersLists = remindersLists
    }

    /// Migrate legacy single-list setting to multi-list on decode
    public mutating func migrateReminders() {
        if let legacy = remindersList, !legacy.isEmpty {
            if !remindersLists.contains(legacy) {
                remindersLists = [legacy]
            }
            remindersList = nil
        }
    }
}
