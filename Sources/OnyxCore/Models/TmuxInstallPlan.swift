//
// TmuxInstallPlan.swift
//
// Responsibility: What a host without tmux needs — what it is, how Onyx
//                 can install tmux there (if it can), and what to tell the
//                 user either way. Built by `TmuxInstall` from a probe.
// Scope: Model. Plain data.
//

import Foundation

/// What `TmuxInstall.probeScript` learned about a host.
public struct TmuxProbe: Equatable {
    public enum Privilege: String, Equatable {
        /// Already root: run the package manager directly.
        case root
        /// sudo exists: it may ask for the user's password, in the terminal.
        case sudo
        /// Neither: `su` asks for root's password, if there is one.
        case none
    }

    public var present: Bool
    /// `uname -s`: "Linux", "Darwin", "FreeBSD"…
    public var system: String
    /// /etc/os-release's ID and ID_LIKE ("ubuntu", ["debian"]).
    public var osID: String
    public var osLike: [String]
    /// Package managers on the PATH, by command name ("apt-get", "brew").
    public var managers: [String]
    public var privilege: Privilege

    public init(present: Bool, system: String, osID: String = "", osLike: [String] = [],
                managers: [String] = [], privilege: Privilege = .none) {
        self.present = present
        self.system = system
        self.osID = osID
        self.osLike = osLike
        self.managers = managers
        self.privilege = privilege
    }
}

/// How to get tmux onto one host.
public struct TmuxInstallPlan: Equatable {
    public var hostID: UUID
    public var hostLabel: String
    /// The package manager Onyx would use ("apt-get"), nil when it can't.
    public var manager: String?
    /// The command to run on the host, in a terminal so a password prompt
    /// can be answered. Nil when Onyx doesn't know how — `advice` says
    /// what to do instead.
    public var command: String?
    /// What will ask for a password, if anything: "sudo", "su" (root's
    /// password, not yours) or nil.
    public var passwordPrompt: String?
    /// One or two sentences on what to do — shown under the explanation.
    public var advice: String
    /// Where to read more when Onyx can't do it.
    public var helpURL: String?
    /// The last install attempt didn't leave tmux behind.
    public var lastAttemptFailed: Bool

    public init(hostID: UUID, hostLabel: String, manager: String?, command: String?,
                passwordPrompt: String?, advice: String, helpURL: String?,
                lastAttemptFailed: Bool = false) {
        self.hostID = hostID
        self.hostLabel = hostLabel
        self.manager = manager
        self.command = command
        self.passwordPrompt = passwordPrompt
        self.advice = advice
        self.helpURL = helpURL
        self.lastAttemptFailed = lastAttemptFailed
    }

    /// The overlay's text.
    public var message: String {
        var lines = ["\(hostLabel) doesn't have tmux, and Onyx needs it: tmux is what keeps your sessions running while you're disconnected."]
        if lastAttemptFailed {
            lines.append("The last install didn't finish — the terminal said why.")
        }
        lines.append(advice)
        return lines.joined(separator: "\n\n")
    }
}
