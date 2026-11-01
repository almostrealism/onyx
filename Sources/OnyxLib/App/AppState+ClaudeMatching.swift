//
// AppState+ClaudeMatching.swift
//
// Responsibility: Matched sessions — which tracked tmux session each
//                 Claude runs in (ClaudeSessionMatching), the last
//                 activity of a session counting its Claudes, and the
//                 remote half: learning hosts' hostnames and checking
//                 tmux for Claudes whose SessionEnd never arrived.
// Scope: Per window for the reads; the periodic work is app-wide (the
//        first window to start it runs it).
//

import Foundation
import OnyxCore

extension AppState {

    // MARK: - Matching

    /// Every live Claude, placed in its session where that's certain.
    var claudeMatches: ClaudeMatches {
        ClaudeSessionMatching.match(claudeSessions.liveSessions, candidates: claudeMatchCandidates())
    }

    /// The Claudes for the CLAUDE SESSIONS list: the ones no session
    /// claims, on the old five-minute rule.
    func unmatchedClaudes(_ matches: ClaudeMatches) -> [ClaudeActivity] {
        let cutoff = Date().addingTimeInterval(-ClaudeSessionManager.quietLimit)
        return matches.unmatched.filter { $0.lastSeen > cutoff }
    }

    func claudeMatchCandidates() -> [ClaudeMatchCandidate] {
        let names = HostMachineNames.shared
        let localName = Self.shortHostName()
        return allSessions.compactMap { session in
            guard session.source.isTmuxBacked, !session.unavailable else { return nil }
            let hostID = session.source.hostID
            guard let host = hosts.first(where: { $0.id == hostID })
                    ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil) else { return nil }
            if case .docker(_, let container) = session.source {
                // A container's Claude reports the container's hostname,
                // which is its name only when it was started that way;
                // and its account is the container's, not ours.
                return ClaudeMatchCandidate(sessionID: session.id, user: "",
                                            machineNames: [container], session: session.name)
            }
            var machineNames = host.isLocal ? [localName] : [host.ssh.host]
            if !host.isLocal, let learned = names.name(for: host.id) { machineNames.append(learned) }
            return ClaudeMatchCandidate(sessionID: session.id,
                                        user: SessionIdentity.effectiveUser(for: host),
                                        machineNames: machineNames, session: session.name)
        }
    }

    // MARK: - Last activity

    /// When a session last did anything: its terminal's last output, or
    /// its Claudes' last hook event, whichever is later. A Claude reports
    /// through hooks whether or not any window has the session open.
    func lastActivity(for session: TmuxSession, in matches: ClaudeMatches) -> Date? {
        let terminal = TerminalActivityStore.shared.lastOutput(for: session.id)
        let claude = matches.lastHeard(in: session.id)
        switch (terminal, claude) {
        case let (t?, c?): return max(t, c)
        default: return terminal ?? claude
        }
    }

    // MARK: - Keeping it true

    /// How often the work below runs, and how often one host's tmux may be
    /// asked about its Claudes.
    static let claudeMatchingTick: TimeInterval = 30
    static let paneCheckInterval: TimeInterval = 120
    /// A Claude heard from this recently is plainly alive.
    static let paneCheckQuiet: TimeInterval = 60

    /// Start the periodic work, once per app.
    func startClaudeMatching() {
        guard NSClassFromString("XCTest") == nil, !ClaudeMatchingWork.started else { return }
        ClaudeMatchingWork.started = true
        Timer.scheduledTimer(withTimeInterval: Self.claudeMatchingTick, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); ClaudeMatchingWork.started = false; return }
            self.claudeMatchingStep()
        }
    }

    func claudeMatchingStep() {
        claudeSessions.gc()
        learnMachineNames()
        checkQuietClaudes()
    }

    /// Ask each usable remote host its `hostname`, once per launch: hooks
    /// name their machine that way, and a host configured by alias or IP
    /// address has nothing else to match it by.
    private func learnMachineNames() {
        let names = HostMachineNames.shared
        let transport = self.transport
        for host in hosts where !host.isLocal && !host.paused && hostUsable(host)
                            && !names.askedThisRun.contains(host.id) {
            guard let release = acquireUtilityChannel("hostname", host: host) else { continue }
            names.markAsked(host.id)
            DispatchQueue.global(qos: .utility).async {
                defer { release() }
                let run = transport.runScript(HostMachineNames.script, on: host, timeout: 8,
                                              label: "hostname:\(host.label)")
                guard let output = run.cleaned else { return }
                DispatchQueue.main.async { names.record(output, for: host.id) }
            }
        }
    }

    /// End matched Claudes whose `SessionEnd` never arrived — the Mac was
    /// asleep or the connection down when they quit. One `tmux list-panes`
    /// per host with a quiet matched Claude, at most every two minutes;
    /// after a sleep it's overdue, so it runs once the host is back.
    private func checkQuietClaudes() {
        let matches = claudeMatches
        let now = Date()
        var quietByHost: [UUID: [ClaudeActivity]] = [:]
        for session in allSessions {
            if case .docker = session.source { continue }   // its tmux isn't the host's
            let quiet = matches.claudes(in: session.id).filter {
                ClaudeSessionManager.reportsItsEnd($0)
                    && now.timeIntervalSince($0.lastSeen) >= Self.paneCheckQuiet
            }
            if !quiet.isEmpty { quietByHost[session.source.hostID, default: []] += quiet }
        }
        let transport = self.transport
        let manager = claudeSessions
        for (hostID, claudes) in quietByHost {
            guard let host = hosts.first(where: { $0.id == hostID })
                    ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil),
                  hostUsable(host) else { continue }
            if let last = ClaudeMatchingWork.lastPaneCheck[hostID],
               now.timeIntervalSince(last) < Self.paneCheckInterval { continue }
            guard let release = acquireUtilityChannel("claude-panes", host: host) else { continue }
            ClaudeMatchingWork.lastPaneCheck[hostID] = now
            DispatchQueue.global(qos: .utility).async {
                defer { release() }
                let run = transport.runScript(ClaudePaneCheck.script, on: host, timeout: 8,
                                              label: "claude-panes:\(host.label)")
                guard let output = run.cleaned else { return }
                let panes = ClaudePaneCheck.parse(output)
                let ended = claudes.filter { $0.origin.map { ClaudePaneCheck.hasEnded($0, panes: panes) } ?? false }
                manager.ended(ended.map(\.id))
            }
        }
    }
}

/// The app-wide half of the periodic work. Main thread only.
enum ClaudeMatchingWork {
    static var started = false
    static var lastPaneCheck: [UUID: Date] = [:]
}
