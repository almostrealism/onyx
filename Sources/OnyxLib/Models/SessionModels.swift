import Foundation

// MARK: - Session Model

public enum SessionSource: Codable, Hashable {
    case host(hostID: UUID)
    case docker(hostID: UUID, containerName: String)
    case dockerLogs(hostID: UUID, containerName: String)
    case dockerTop(hostID: UUID, containerName: String)
    case browser(url: String)

    public var hostID: UUID {
        switch self {
        case .host(let id): return id
        case .docker(let id, _): return id
        case .dockerLogs(let id, _): return id
        case .dockerTop(let id, _): return id
        case .browser: return HostConfig.localhostID
        }
    }

    public var stableKey: String {
        switch self {
        case .host(let id): return "host:\(id.uuidString)"
        case .docker(let id, let name): return "docker:\(id.uuidString):\(name)"
        case .dockerLogs(let id, let name): return "dockerlogs:\(id.uuidString):\(name)"
        case .dockerTop(let id, let name): return "dockertop:\(id.uuidString):\(name)"
        case .browser(let url): return "browser:\(url)"
        }
    }

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

    public var isBrowser: Bool {
        if case .browser = self { return true }
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

    public var browserURL: String? {
        if case .browser(let url) = self { return url }
        return nil
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
        case .browser: return name
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
