//
// ClaudeSessionMatching.swift
//
// Responsibility: Decide which tracked tmux session each Claude is running
//                 in (a "matched session"), and whether a tmux pane check
//                 says a Claude has ended. Pure; the App layer gathers the
//                 inputs and runs the remote half.
// Scope: Stateless.
//

import Foundation

/// One tracked tmux session a Claude could be running in.
public struct ClaudeMatchCandidate: Equatable {
    /// `TmuxSession.id`.
    public let sessionID: String
    /// The account Onyx connects as.
    public let user: String
    /// Every name the host's machine may report: the configured host, and
    /// the `hostname` Onyx learned from it.
    public let machineNames: [String]
    /// The tmux session's name.
    public let session: String

    public init(sessionID: String, user: String, machineNames: [String], session: String) {
        self.sessionID = sessionID
        self.user = user
        self.machineNames = machineNames
        self.session = session
    }
}

/// Every Claude, sorted into the sessions it's running in and the ones
/// Onyx can't place.
public struct ClaudeMatches {
    /// Claudes per `TmuxSession.id`, most recently heard from first.
    public var bySession: [String: [ClaudeActivity]] = [:]
    /// Claudes that fit no session, or more than one.
    public var unmatched: [ClaudeActivity] = []

    public init(bySession: [String: [ClaudeActivity]] = [:], unmatched: [ClaudeActivity] = []) {
        self.bySession = bySession
        self.unmatched = unmatched
    }

    /// The Claudes in a session; empty when it isn't matched.
    public func claudes(in sessionID: String) -> [ClaudeActivity] {
        bySession[sessionID] ?? []
    }

    /// The most recent hook event from any Claude in a session.
    public func lastHeard(in sessionID: String) -> Date? {
        claudes(in: sessionID).map(\.lastSeen).max()
    }

    /// Which session a Claude was matched to.
    public func sessionID(of claudeID: String) -> String? {
        bySession.first { $0.value.contains { $0.id == claudeID } }?.key
    }
}

public enum ClaudeSessionMatching {

    /// Sort `activities` into sessions. A Claude matches only when exactly
    /// one candidate fits; an ambiguous fit is no fit, because a Claude
    /// shown in the wrong session is worse than one shown on its own.
    public static func match(_ activities: [ClaudeActivity],
                             candidates: [ClaudeMatchCandidate]) -> ClaudeMatches {
        var result = ClaudeMatches()
        for activity in activities.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            if let origin = activity.origin, let id = sessionID(for: origin, in: candidates) {
                result.bySession[id, default: []].append(activity)
            } else {
                result.unmatched.append(activity)
            }
        }
        return result
    }

    /// The one session `origin` names, or nil.
    ///
    /// The account is matched first and then ignored if nothing fits: a
    /// Claude under `su` reports the account it became, not the one Onyx
    /// connected as, while the machine and the tmux session — the things
    /// that actually single it out — are still right.
    public static func sessionID(for origin: HookOrigin,
                                 in candidates: [ClaudeMatchCandidate]) -> String? {
        guard let session = origin.session, !session.isEmpty else { return nil }
        let machine = origin.machine.lowercased()
        let placed = candidates.filter { c in
            c.session == session
                && c.machineNames.contains { name in
                    let n = name.lowercased()
                    return !n.isEmpty && AlertRouting.hostMatches(n, machine)
                }
        }
        if let user = origin.user?.lowercased(), !user.isEmpty {
            let exact = placed.filter { $0.user.lowercased() == user }
            if exact.count == 1 { return exact[0].sessionID }
            if !exact.isEmpty { return nil }
        }
        return placed.count == 1 ? placed[0].sessionID : nil
    }
}

// MARK: - Has it ended?

/// Asks a host's tmux whether matched Claudes are still running, for when
/// their `SessionEnd` never arrived (the Mac was asleep, the connection
/// was down). One small command per host.
public enum ClaudePaneCheck {

    /// Every pane: its id, what it's running, and its session (last, since
    /// a session name may contain spaces).
    public static let script =
        "tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{session_name}' 2>/dev/null"

    public struct Pane: Equatable {
        public let command: String
        public let session: String
    }

    /// Pane id → pane. Anything not shaped like a pane line (an echo of
    /// the script, a login banner) is skipped.
    public static func parse(_ output: String) -> [String: Pane] {
        var panes: [String: Pane] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0].hasPrefix("%"),
                  Int(parts[0].dropFirst()) != nil else { continue }
            panes[String(parts[0])] = Pane(command: String(parts[1]), session: String(parts[2]))
        }
        return panes
    }

    /// Shells: a pane back at one of these has no Claude in front.
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu"]

    /// Whether the Claude at `origin` has certainly ended.
    ///
    /// Only a definite answer ends one: its pane is gone while its tmux
    /// session is still there, or its pane is back at a shell. A tmux
    /// session missing from the output altogether says nothing — it may
    /// live on another tmux server — and no pane to go by says nothing
    /// either.
    public static func hasEnded(_ origin: HookOrigin, panes: [String: Pane]) -> Bool {
        guard let paneID = origin.pane, let session = origin.session else { return false }
        guard let pane = panes[paneID] else {
            return panes.values.contains { $0.session == session }
        }
        var command = pane.command
        if command.hasPrefix("-") { command.removeFirst() }   // a login shell
        return shells.contains(command)
    }
}
