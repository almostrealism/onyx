import Foundation

/// One-shot snapshot of a host's SSH mux state, with enough detail to
/// debug why a connection isn't coming up. Built by
/// `AppState.diagnoseSSHMux(for:)` on demand and rendered inline in the
/// monitor overlay's SSH MUX section.
public struct SSHMuxDiagnostic: Equatable {
    /// True iff `ssh -O check` returned 0.
    public let muxAlive: Bool
    /// Full path of the control socket — the ControlPath we pass to ssh.
    public let controlPath: String
    /// Whether the socket file currently exists on disk.
    public let socketExists: Bool
    /// Age in seconds since the socket was last modified, nil if absent.
    public let socketAgeSeconds: TimeInterval?
    /// The exact command we ran for the check. Useful both for the user
    /// to re-run themselves AND for paste-it-in-bug-reports debugging.
    public let checkCommand: String
    /// Combined stdout+stderr from the check. Captures messages like
    /// "Control socket connect: No such file or directory" or
    /// "Permission denied (publickey)".
    public let checkOutput: String
    /// Exit code (nil if the ssh process failed to launch).
    public let checkExitCode: Int32?
    public let host: HostConfig
    public let timestamp: Date

    public var summary: String {
        if muxAlive { return "Mux is alive" }
        if !socketExists { return "No mux socket — connection never established" }
        if let age = socketAgeSeconds, age > 60 {
            return "Stale mux socket (\(Int(age))s old) — try Reset"
        }
        if checkExitCode == nil { return "ssh failed to launch" }
        return "Mux check failed (exit \(checkExitCode ?? -1))"
    }
}

/// Result of an explicit "ssh -v" connection test that doesn't depend on
/// the mux at all — just verifies basic auth + reachability.
public struct SSHConnectTest: Equatable {
    public let host: HostConfig
    public let success: Bool
    public let command: String
    public let output: String
    public let exitCode: Int32?
    public let timestamp: Date
}
