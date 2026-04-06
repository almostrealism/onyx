import Foundation

// MARK: - Connection Pool Info

/// ConnectionStatus.
public enum ConnectionStatus: Equatable {
    case active         // currently displayed, process running
    case connected      // pooled, process running, not displayed
    case disconnected   // pooled, process dead
    case connecting     // SSH process just started, waiting for auth
    case reconnecting   // backoff delay before retry
    case enumerating    // re-enumerating sessions before connecting

    /// Label.
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

    /// Color.
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

    /// Is transient.
    public var isTransient: Bool {
        switch self {
        case .connecting, .reconnecting, .enumerating: return true
        default: return false
        }
    }
}

/// ConnectionInfo.
public struct ConnectionInfo: Identifiable {
    /// Id.
    public let id: String           // session ID from pool
    /// Label.
    public let label: String        // display name
    /// Host label.
    public let hostLabel: String    // host name
    /// Is running.
    public let isRunning: Bool      // process is alive
    /// Is active.
    public let isActive: Bool       // currently displayed terminal
    /// Last active time.
    public let lastActiveTime: Date
    /// Source.
    public let source: SessionSource?
    /// Connection status.
    public let connectionStatus: ConnectionStatus

    /// Status.
    public var status: String { connectionStatus.label }
    /// Status color.
    public var statusColor: String { connectionStatus.color }
}
