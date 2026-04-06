import Foundation

// MARK: - Connection Pool Info

public enum ConnectionStatus: Equatable {
    case active         // currently displayed, process running
    case connected      // pooled, process running, not displayed
    case disconnected   // pooled, process dead
    case connecting     // SSH process just started, waiting for auth
    case reconnecting   // backoff delay before retry
    case enumerating    // re-enumerating sessions before connecting

    public var label: String {
        switch self {
        case .active: return "active"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .reconnecting: return "reconnecting"
        case .enumerating: return "enumerating"
        }
    }

    public var color: String {
        switch self {
        case .active: return "6BFF8E"           // green
        case .connected: return "FFD06B"         // yellow
        case .disconnected: return "FF6B6B"      // red
        case .connecting: return "66CCFF"         // blue
        case .reconnecting: return "C06BFF"       // purple
        case .enumerating: return "66CCFF"        // blue
        }
    }

    public var isTransient: Bool {
        switch self {
        case .connecting, .reconnecting, .enumerating: return true
        default: return false
        }
    }
}

public struct ConnectionInfo: Identifiable {
    public let id: String           // session ID from pool
    public let label: String        // display name
    public let hostLabel: String    // host name
    public let isRunning: Bool      // process is alive
    public let isActive: Bool       // currently displayed terminal
    public let lastActiveTime: Date
    public let source: SessionSource?
    public let connectionStatus: ConnectionStatus

    public var status: String { connectionStatus.label }
    public var statusColor: String { connectionStatus.color }
}
