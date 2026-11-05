//
// SessionWidgetSnapshot.swift
//
// Responsibility: What the session widget shows, as the app writes it and
//                 the widget reads it: the rows, when they were made, and
//                 where the file lives — the App Group container both
//                 share (docs/compact-window-and-widget-plan.md).
// Scope: Pure data and file IO. No dependencies, so the widget extension
//        links only this target.
//

import Foundation
#if os(macOS)
import Security
#endif

/// One session in the widget: a row of the sessions list.
public struct SessionWidgetRow: Codable, Hashable, Identifiable {

    /// What its Claude is doing, if it has one.
    public enum Claude: String, Codable, Hashable {
        case running, waitingPermission, waitingForYou, idle
    }

    /// `TmuxSession.id`, which the deep link carries back.
    public let id: String
    /// The note, else the session's name.
    public let title: String
    /// The second line: the Claude's activity, or where the session is
    /// when the title is its note.
    public let detail: String?
    public let claude: Claude?
    /// How many Claudes beyond the one the detail describes.
    public let moreClaudes: Int
    /// Terminal output or Claude hook, whichever came last.
    public let lastActivity: Date?
    /// Its ⌘N position in the favorites bar.
    public let shortcut: Int?

    public init(id: String, title: String, detail: String?, claude: Claude?,
                moreClaudes: Int = 0, lastActivity: Date?, shortcut: Int?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.claude = claude
        self.moreClaudes = moreClaudes
        self.lastActivity = lastActivity
        self.shortcut = shortcut
    }

    /// The row with its clock removed — what decides whether a change is
    /// worth a widget reload rather than only a file write.
    var withoutClock: SessionWidgetRow {
        SessionWidgetRow(id: id, title: title, detail: detail, claude: claude,
                         moreClaudes: moreClaudes, lastActivity: nil, shortcut: shortcut)
    }
}

public struct SessionWidgetSnapshot: Codable, Equatable {
    public static let currentVersion = 1

    public var version = currentVersion
    /// When these rows were made.
    public var generatedAt: Date
    /// When the app last said it was running, rows changed or not.
    public var heartbeatAt: Date
    public var rows: [SessionWidgetRow]

    public init(generatedAt: Date, heartbeatAt: Date, rows: [SessionWidgetRow]) {
        self.generatedAt = generatedAt
        self.heartbeatAt = heartbeatAt
        self.rows = rows
    }

    /// Past this without a heartbeat the app isn't running (or can't
    /// write), and the widget says so instead of passing old rows off as
    /// live.
    public static let staleAfter: TimeInterval = 15 * 60

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(heartbeatAt) > Self.staleAfter
    }

    /// Sessions whose Claude is waiting on a permission.
    public var waitingCount: Int { rows.filter { $0.claude == .waitingPermission }.count }
}

/// How lately a session did something, for its dot — the same thresholds
/// as the sessions list in the app.
public enum SessionActivityLevel: Equatable {
    case active, recent, quiet, unknown

    public static func of(idleSeconds: TimeInterval?) -> SessionActivityLevel {
        guard let idle = idleSeconds else { return .unknown }
        if idle < 15 { return .active }
        if idle < 120 { return .recent }
        return .quiet
    }

    /// The idle ages at which a dot changes color.
    public static let thresholds: [TimeInterval] = [15, 120]
}

/// `onyx://session?id=…` — what a click on the widget opens.
public enum SessionLink {
    public static let scheme = "onyx"

    public static func url(for sessionID: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "session"
        parts.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return parts.url
    }

    public static func sessionID(in url: URL) -> String? {
        guard url.scheme == scheme, url.host == "session",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return nil }
        return id
    }
}

/// The file both sides use, in the App Group container.
public enum SessionWidgetStore {

    /// The widget's WidgetKit kind.
    public static let kind = "OnyxSessions"
    static let fileName = "sessions-widget.json"

    /// The App Group: Team-ID-prefixed, which Developer ID builds can use
    /// without a provisioning profile.
    public static func groupID(teamID: String) -> String { "\(teamID).ai.almostrealism.onyx" }

    /// The team this process was signed by — nil when it wasn't signed by
    /// one (`swift run`, an ad-hoc build), which has no group to share.
    public static func signingTeamID() -> String? {
        #if os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
        #else
        return nil
        #endif
    }

    /// The snapshot file for this process's team, or nil without one.
    public static func fileURL(fileManager: FileManager = .default) -> URL? {
        guard let team = signingTeamID(),
              let dir = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupID(teamID: team))
        else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    public static func read(from url: URL) -> SessionWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(SessionWidgetSnapshot.self, from: data),
              snapshot.version == SessionWidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Written whole and atomically: the widget may read at any moment.
    public static func write(_ snapshot: SessionWidgetSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// When the app writes the file and when it asks WidgetKit to reload.
///
/// WidgetKit rations reloads, so they're kept for changes worth seeing:
/// at once when a Claude starts waiting for permission, at most once a
/// minute for anything else in a row, and at most every five minutes
/// when only the clocks moved. The file itself is cheap and is written on
/// any change, plus a heartbeat so the widget can tell a quiet app from
/// one that isn't running.
public struct SessionWidgetPacing {
    public static let reloadInterval: TimeInterval = 60
    public static let clockReloadInterval: TimeInterval = 300
    public static let heartbeatInterval: TimeInterval = 5 * 60

    public private(set) var written: [SessionWidgetRow]?
    public private(set) var reloaded: [SessionWidgetRow]?
    public private(set) var lastWrite: Date?
    public private(set) var lastReload: Date?

    public init() {}

    public struct Decision: Equatable {
        public var write: Bool
        public var reload: Bool
    }

    public mutating func step(_ rows: [SessionWidgetRow], now: Date) -> Decision {
        let changed = rows != written
        let heartbeatDue = lastWrite.map { now.timeIntervalSince($0) >= Self.heartbeatInterval } ?? true
        let write = changed || heartbeatDue

        var reload = false
        if rows != reloaded {
            let shown = reloaded ?? []
            let newlyWaiting = rows.contains { row in
                row.claude == .waitingPermission
                    && !shown.contains { $0.id == row.id && $0.claude == .waitingPermission }
            }
            let sinceReload = lastReload.map { now.timeIntervalSince($0) } ?? .infinity
            let onlyClocks = rows.map(\.withoutClock) == shown.map(\.withoutClock)
            reload = newlyWaiting
                || (!onlyClocks && sinceReload >= Self.reloadInterval)
                || (onlyClocks && sinceReload >= Self.clockReloadInterval)
        }
        if write { written = rows; lastWrite = now }
        if reload { reloaded = rows; lastReload = now }
        return Decision(write: write, reload: reload)
    }
}
