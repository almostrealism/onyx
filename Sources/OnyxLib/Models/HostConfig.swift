import Foundation

// MARK: - Host Config

/// SSHConfig.
public struct SSHConfig: Codable, Hashable {
    /// Host.
    public var host: String = ""
    /// User.
    public var user: String = ""
    /// Port.
    public var port: Int = 22
    /// Tmux session.
    public var tmuxSession: String = "onyx"
    /// Identity file.
    public var identityFile: String = ""

    /// Create a new instance.
    public init(host: String = "", user: String = "", port: Int = 22, tmuxSession: String = "onyx", identityFile: String = "") {
        self.host = host
        self.user = user
        self.port = port
        self.tmuxSession = tmuxSession
        self.identityFile = identityFile
    }
}

/// HostConfig.
public struct HostConfig: Codable, Identifiable, Hashable {
    /// Id.
    public var id: UUID
    /// Label.
    public var label: String
    /// Ssh.
    public var ssh: SSHConfig

    /// Create a new instance.
    public init(id: UUID = UUID(), label: String, ssh: SSHConfig = SSHConfig()) {
        self.id = id
        self.label = label
        self.ssh = ssh
    }

    /// Is local.
    public var isLocal: Bool {
        let h = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h.isEmpty
    }

    /// Localhost id.
    public static let localhostID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Localhost.
    public static var localhost: HostConfig {
        HostConfig(id: localhostID, label: "localhost", ssh: SSHConfig())
    }
}

/// AppearanceConfig.
public struct AppearanceConfig: Codable {
    /// Font size.
    public var fontSize: Double = 13           // legacy, maps to terminalFontSize
    /// Terminal font size.
    public var terminalFontSize: Double?        // nil = use fontSize for backward compat
    /// Terminal font name.
    public var terminalFontName: String = "SF Mono"
    /// Ui font size.
    public var uiFontSize: Double = 12
    /// Window opacity.
    public var windowOpacity: Double = 0.82
    /// Accent hex.
    public var accentHex: String = "66CCFF"
    /// Per-window accent color overrides. Key = window index (0-3), value = hex color.
    /// Windows without an entry use the global accentHex.
    public var windowAccents: [Int: String] = [:]
    /// Window title.
    public var windowTitle: String = "Onyx"
    /// Reminders list.
    public var remindersList: String?       // deprecated: migrated to remindersLists
    /// Reminders lists.
    public var remindersLists: [String] = [] // empty = "Today" mode
    /// Last active session ID per window index, for session restore on startup
    public var lastSessionByWindow: [Int: String] = [:]
    /// Up to 3 additional timezone identifiers for monitor clocks (e.g., "America/New_York")
    public var extraTimezones: [String] = []
    /// Whether to use 12-hour (AM/PM) format for clocks (UTC always stays 24hr)
    public var use12HourClock: Bool = false
    /// When true, Claude Code PreToolUse hooks block waiting for the user to
    /// approve/deny a tool call from the Onyx UI. Off by default — when off,
    /// Claude's normal in-terminal permission prompt is used.
    public var claudeHooksGatePermissions: Bool = false
    /// When true, draws a 2px orange outline around whichever component
    /// currently holds keyboard focus (terminal / right panel / overlay).
    /// Useful when debugging focus-routing issues; off by default because
    /// it's visually noisy in normal use.
    public var showFocusOutline: Bool = false

    /// Effective terminal font size.
    public var effectiveTerminalFontSize: Double {
        terminalFontSize ?? fontSize
    }

    /// Accent options.
    public static let accentOptions = ["66CCFF", "FF6B6B", "6BFF8E", "FFD06B", "C06BFF", "FF6BCD"]

    /// Terminal font options.
    public static let terminalFontOptions = [
        "SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono",
        "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono",
        "Hack", "Inconsolata"
    ]

    /// Create a new instance.
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

    // Forward-compatible decode: every field is decoded with a default
    // fallback so adding a new field never makes existing user configs
    // fail to decode (and silently get wiped by AppearanceStore.load).
    // **If you add a field above, add a matching decodeIfPresent line
    // here.** A test in Tests/OnyxTests/Models/ModelsTests.swift verifies
    // a stripped-down JSON still decodes to defaults for missing keys.
    private enum CodingKeys: String, CodingKey {
        case fontSize, terminalFontSize, terminalFontName, uiFontSize
        case windowOpacity, accentHex, windowAccents, windowTitle
        case remindersList, remindersLists, lastSessionByWindow
        case extraTimezones, use12HourClock
        case claudeHooksGatePermissions, showFocusOutline
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSize                   = try c.decodeIfPresent(Double.self,         forKey: .fontSize)                   ?? 13
        self.terminalFontSize           = try c.decodeIfPresent(Double.self,         forKey: .terminalFontSize)
        self.terminalFontName           = try c.decodeIfPresent(String.self,         forKey: .terminalFontName)           ?? "SF Mono"
        self.uiFontSize                 = try c.decodeIfPresent(Double.self,         forKey: .uiFontSize)                 ?? 12
        self.windowOpacity              = try c.decodeIfPresent(Double.self,         forKey: .windowOpacity)              ?? 0.82
        self.accentHex                  = try c.decodeIfPresent(String.self,         forKey: .accentHex)                  ?? "66CCFF"
        self.windowAccents              = try c.decodeIfPresent([Int: String].self,  forKey: .windowAccents)              ?? [:]
        self.windowTitle                = try c.decodeIfPresent(String.self,         forKey: .windowTitle)                ?? "Onyx"
        self.remindersList              = try c.decodeIfPresent(String.self,         forKey: .remindersList)
        self.remindersLists             = try c.decodeIfPresent([String].self,       forKey: .remindersLists)             ?? []
        self.lastSessionByWindow        = try c.decodeIfPresent([Int: String].self,  forKey: .lastSessionByWindow)        ?? [:]
        self.extraTimezones             = try c.decodeIfPresent([String].self,       forKey: .extraTimezones)             ?? []
        self.use12HourClock             = try c.decodeIfPresent(Bool.self,           forKey: .use12HourClock)             ?? false
        self.claudeHooksGatePermissions = try c.decodeIfPresent(Bool.self,           forKey: .claudeHooksGatePermissions) ?? false
        self.showFocusOutline           = try c.decodeIfPresent(Bool.self,           forKey: .showFocusOutline)           ?? false
    }
}
