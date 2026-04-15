import Foundation

// MARK: - Session Model

/// SessionSource.
public enum SessionSource: Codable, Hashable {
    case host(hostID: UUID)
    case docker(hostID: UUID, containerName: String)
    case dockerLogs(hostID: UUID, containerName: String)
    case dockerTop(hostID: UUID, containerName: String)
    case browser(url: String)

    /// Host id.
    public var hostID: UUID {
        switch self {
        case .host(let id): return id
        case .docker(let id, _): return id
        case .dockerLogs(let id, _): return id
        case .dockerTop(let id, _): return id
        case .browser: return HostConfig.localhostID
        }
    }

    /// Stable key.
    public var stableKey: String {
        switch self {
        case .host(let id): return "host:\(id.uuidString)"
        case .docker(let id, let name): return "docker:\(id.uuidString):\(name)"
        case .dockerLogs(let id, let name): return "dockerlogs:\(id.uuidString):\(name)"
        case .dockerTop(let id, let name): return "dockertop:\(id.uuidString):\(name)"
        case .browser(let url): return "browser:\(url)"
        }
    }

    /// Display name.
    public var displayName: String {
        switch self {
        case .host: return "Host"
        case .docker(_, let name): return name
        case .dockerLogs(_, let name): return "\(name) logs"
        case .dockerTop(_, let name): return "\(name) processes"
        case .browser(let url):
            // Show domain for display
            if let host = URL(string: url)?.host { return host }
            return "Browser"
        }
    }

    /// Is docker.
    public var isDocker: Bool {
        switch self {
        case .docker, .dockerLogs, .dockerTop: return true
        default: return false
        }
    }

    /// Is docker logs.
    public var isDockerLogs: Bool {
        if case .dockerLogs = self { return true }
        return false
    }

    /// Is docker top.
    public var isDockerTop: Bool {
        if case .dockerTop = self { return true }
        return false
    }

    /// Is browser.
    public var isBrowser: Bool {
        if case .browser = self { return true }
        return false
    }

    /// True for pseudo-sessions that are not interactive tmux sessions
    public var isUtility: Bool {
        isDockerLogs || isDockerTop
    }

    /// Container name.
    public var containerName: String? {
        switch self {
        case .docker(_, let name): return name
        case .dockerLogs(_, let name): return name
        case .dockerTop(_, let name): return name
        default: return nil
        }
    }

    /// Browser url.
    public var browserURL: String? {
        if case .browser(let url) = self { return url }
        return nil
    }

    /// Grouping key for the session list. Sessions with the same groupKey
    /// appear under the same header. Host/docker use the host UUID;
    /// browser and future local types use the localhost UUID.
    public var groupHostID: UUID {
        switch self {
        case .host(let id), .docker(let id, _), .dockerLogs(let id, _), .dockerTop(let id, _):
            return id
        case .browser:
            return HostConfig.localhostID
        }
    }

    /// Sub-group key within a host group. Docker variants group by container;
    /// host sessions share a single key; browsers each get their own entry.
    public var subGroupKey: String {
        switch self {
        case .host(let id):
            return SessionSource.host(hostID: id).stableKey
        case .docker(let id, let name), .dockerLogs(let id, let name), .dockerTop(let id, let name):
            return SessionSource.docker(hostID: id, containerName: name).stableKey
        case .browser:
            return stableKey
        }
    }

    /// True for session types that are not bound to a specific remote host
    /// (browser, and future local-only types like editors, players, etc.)
    public var isLocal: Bool {
        switch self {
        case .browser: return true
        default: return false
        }
    }
}

/// TmuxSession.
public struct TmuxSession: Identifiable, Hashable {
    /// Name.
    public let name: String
    /// Source.
    public let source: SessionSource
    /// Unavailable.
    public let unavailable: Bool

    /// Create a new instance.
    public init(name: String, source: SessionSource, unavailable: Bool = false) {
        self.name = name
        self.source = source
        self.unavailable = unavailable
    }

    /// Id.
    public var id: String { "\(source.stableKey):\(name)" }

    /// Display label.
    public var displayLabel: String {
        switch source {
        case .host: return name
        case .docker(_, let container): return "\(container)/\(name)"
        case .dockerLogs(_, let container): return "\(container)/logs"
        case .dockerTop(_, let container): return "\(container)/top"
        case .browser: return name
        }
    }
}

/// SessionGroup.
public struct SessionGroup: Identifiable {
    /// Id.
    public var id: String { source.stableKey }
    /// Source.
    public let source: SessionSource
    /// Sessions.
    public let sessions: [TmuxSession]
}

/// HostGroup.
public struct HostGroup: Identifiable {
    /// Id.
    public var id: UUID { host.id }
    /// Host.
    public let host: HostConfig
    /// Groups.
    public let groups: [SessionGroup]
}

/// A persisted browser session entry for saving/loading from disk.
public struct PersistedSession: Codable {
    /// Display name.
    public let name: String
    /// Stable key from SessionSource (e.g. "browser:https://github.com").
    public let sourceStableKey: String

    public init(name: String, sourceStableKey: String) {
        self.name = name
        self.sourceStableKey = sourceStableKey
    }
}
