//
// TerminalSessionSwitching.swift
//
// Responsibility: Finding out what sessions exist on a host, and moving
//                 the terminal between them.
// Scope: An extension on OnyxTerminalView (the terminal pool). Split from
//        TerminalSessionManager.swift, which was 36 lines from SwiftLint's
//        hard type-body limit — the threshold in .swiftlint.yml was raised
//        for this file specifically, with a note saying to restore it once
//        the file was split. This is that split.
//
// Nothing here changed in the move.
//
// The rule that governs everything in this file: ASYNC BOUNDARIES PRESERVE
// IDENTITY. Enumeration and switching both hop threads repeatedly, and the
// active session can change underneath them — so anything acting on "the
// active session" re-verifies `appState.activeSession?.id` after every
// hop. Reconnect bugs in this app have almost always been a missing
// re-check here.
//

import AppKit
import SwiftTerm

extension OnyxTerminalView {
    // A handful of members below are internal rather than private: they
    // are called from the other half of this type, and Swift's `private`
    // does not reach across files.

    // MARK: - Session Enumeration

    func enumerateAllSessions(then completion: @escaping () -> Void) {
        isEnumerating = true
        DispatchQueue.main.async { self.appState.isEnumeratingSessions = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let hosts = self.appState.hosts
            let store = NetworkTopologyStore.shared

            let group = DispatchGroup()
            let lock = NSLock()
            var allEnumerated: [(hostID: UUID, sessions: [TmuxSession], probe: ProbeStatus)] = []

            for host in hosts {
                group.enter()
                self.enumerateHostSessions(host) { sessions, probeResult in
                    lock.lock()
                    allEnumerated.append((hostID: host.id, sessions: sessions, probe: probeResult))
                    lock.unlock()
                    group.leave()
                }
            }

            group.wait()
            self.lastEnumerationTime = Date()

            // Merge each host's results into the topology store
            for result in allEnumerated {
                store.mergeEnumeration(hostID: result.hostID, sessions: result.sessions, probeResult: result.probe)
            }
            store.save()

            // Build session list from topology (includes stale entries as unavailable)
            let topologySessions = store.deriveSessions()

            // Check for missing favorited sessions that can be recreated
            let allResults = allEnumerated.flatMap(\.sessions)
            let createdSessions = self.recreateMissingFavorites(existing: allResults, hosts: hosts)
            var finalResults = topologySessions + createdSessions.filter { created in
                !topologySessions.contains(where: { $0.id == created.id })
            }

            // Preserve sessions that have active pool entries — they're provably
            // connected and must not vanish just because enumeration missed them
            let finalIDs = Set(finalResults.map(\.id))
            let pooledSessions = self.appState.allSessions.filter { session in
                !finalIDs.contains(session.id) && self.pool[session.id]?.processRunning == true
            }
            finalResults.append(contentsOf: pooledSessions)

            DispatchQueue.main.async {
                self.isEnumerating = false
                if finalResults.isEmpty {
                    let defaultHost = self.appState.hosts.first ?? .localhost
                    let fallback = TmuxSession(
                        name: defaultHost.ssh.tmuxSession,
                        source: .host(hostID: defaultHost.id)
                    )
                    self.appState.allSessions = [fallback]
                    if self.appState.activeSession == nil {
                        self.appState.activeSession = fallback
                    }
                } else {
                    self.appState.allSessions = finalResults
                    // Only reassign active session if there is none at all.
                    // Prefer: restored session from last use > first favorite > default host session > first found
                    if self.appState.activeSession == nil {
                        let restoredID = self.appState.restoredSessionID
                        let restored = restoredID.flatMap { id in finalResults.first { $0.id == id } }
                        let firstFav = self.appState.favoriteSessions.first
                        let defaultHost = self.appState.hosts.first ?? .localhost
                        let defaultMatch = finalResults.first {
                            $0.source.hostID == defaultHost.id
                                && $0.name == defaultHost.ssh.tmuxSession
                                && !$0.source.isDocker
                        }
                        self.appState.activeSession = restored ?? firstFav ?? defaultMatch ?? finalResults.first
                    }
                }
                self.appState.isEnumeratingSessions = false
                completion()
            }
        }
    }

    /// Recreate favorited tmux sessions that no longer exist on reachable hosts.
    /// Only creates sessions when we're confident the host is reachable and tmux
    /// simply doesn't have that session — never on probe failure or SSH errors.
    private func recreateMissingFavorites(existing: [TmuxSession], hosts: [HostConfig]) -> [TmuxSession] {
        let existingIDs = Set(existing.map(\.id))
        let favoriteIDs = appState.favoritedSessionIDs
        let reachableHostIDs = Set(existing.map(\.source.hostID))

        // Running docker container names per host (from existing enumeration)
        var runningContainers: [UUID: Set<String>] = [:]
        for session in existing {
            if let container = session.source.containerName {
                runningContainers[session.source.hostID, default: []].insert(container)
            }
        }

        var created: [TmuxSession] = []

        for favID in favoriteIDs {
            guard !existingIDs.contains(favID) else { continue }
            guard let session = appState.parseFavoriteID(favID) else { continue }

            let hostID = session.source.hostID
            guard let host = hosts.first(where: { $0.id == hostID }) else { continue }

            // Only recreate if we know the host is reachable (it returned sessions or is local)
            guard host.isLocal || reachableHostIDs.contains(hostID) else { continue }

            // Local sessions (browser, etc.) don't need remote recreation —
            // just add them back to the session list.
            if session.source.isLocal {
                print("recreateMissingFavorites: restored local session \(session.displayLabel)")
                created.append(session)
                continue
            }

            let safeName = appState.sanitizedSession(session.name)
            let script: String

            switch session.source {
            case .host:
                // Create a detached tmux session on the host
                script = "tmux new-session -d -s \(safeName) 2>/dev/null && echo CREATED || echo EXISTS"
            case .docker(_, let container):
                // Only if the container is currently running
                guard runningContainers[hostID]?.contains(container) == true else { continue }
                let safeContainer = appState.sanitizedContainer(container)
                script = "docker exec \(safeContainer) tmux new-session -d -s \(safeName) 2>/dev/null && echo CREATED || echo EXISTS"
            default:
                continue
            }

            let (cmd, args) = appState.remoteCommand(script, host: host)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }

            // Only add to results if the command succeeded (exit 0)
            guard process.terminationStatus == 0 else { continue }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard output.contains("CREATED") || output.contains("EXISTS") else { continue }

            print("recreateMissingFavorites: recreated \(session.displayLabel)")
            created.append(session)
        }

        return created
    }

    func enumerateHostSessions(_ host: HostConfig, completion: @escaping ([TmuxSession], ProbeStatus) -> Void) {
        // Paused: no probe, no tmux ls, no docker ps. `.unreachable` leaves
        // the topology store's session entries untouched, so the host's
        // sessions stay listed exactly as they were.
        if host.paused {
            completion([], .unreachable)
            return
        }
        DispatchQueue.main.async {
            self.appState.startupStatus = "Probing \(host.label)..."
        }
        // For remote hosts, probe first
        if !host.isLocal {
            let result = probeHost(host)
            let probeStatus: ProbeStatus
            switch result {
            case .ok: probeStatus = .ok
            case .unreachable: probeStatus = .unreachable
            case .keyAuthFailed: probeStatus = .keyAuthFailed
            }

            if result == .keyAuthFailed {
                let hostID = host.id
                let label = host.label
                DispatchQueue.main.async {
                    // Guard against race: host may have been removed while probe was running
                    guard self.appState.hosts.contains(where: { $0.id == hostID }) else { return }
                    // Last line of defense: never demand a key for a host
                    // we're demonstrably connected to. The probe and the
                    // connection pair are independent, and the pair is the
                    // one with actual evidence.
                    guard !self.appState.hostUsable(host) else {
                        DiagnosticLog.shared.record("key",
                            "\(label): probe said key-auth, but the host is connected — prompt suppressed")
                        OnyxLog.session.notice("""
                            suppressing key-setup prompt for \(label, privacy: .public) —                             the host is connected
                            """)
                        return
                    }
                    DiagnosticLog.shared.record("key",
                        "\(label): authentication refused — asking for key setup", failure: true)
                    self.appState.needsKeySetup = true
                    self.appState.keySetupHostID = hostID
                    self.setHostState(
                        .needsKeySetup(error: "Key authentication failed for \(label).\nInstall your SSH key to connect."),
                        hostID: hostID
                    )
                }
                completion([], probeStatus)
                return
            } else if result == .unreachable {
                completion([], probeStatus)
                return
            }
        }

        let group = DispatchGroup()
        var hostSessions: [TmuxSession] = []
        var dockerSessions: [TmuxSession] = []
        let lock = NSLock()

        group.enter()
        fetchTmuxSessions(host: host, source: .host(hostID: host.id)) { sessions in
            lock.lock()
            hostSessions = sessions
            lock.unlock()
            group.leave()
        }

        group.enter()
        fetchDockerContainerSessions(host: host) { sessions in
            lock.lock()
            dockerSessions = sessions
            lock.unlock()
            group.leave()
        }

        group.wait()
        completion(hostSessions + dockerSessions, .ok)
    }

    private func fetchTmuxSessions(host: HostConfig, source: SessionSource, completion: @escaping ([TmuxSession]) -> Void) {
        let script: String
        switch source {
        case .host:
            // `session_activity` is tmux's own unix timestamp of the last
            // activity in the session — the answer to the question the
            // idle indicator is asking, for every session on the host, in
            // the command we were already running.
            script = "tmux ls -F \"#{session_name}|#{session_activity}\" 2>/dev/null || true"
        case .docker(_, let containerName):
            let safe = appState.sanitizedContainer(containerName)
            script = "docker exec \(safe) tmux ls -F \"#{session_name}|#{session_activity}\" 2>/dev/null || true"
        case .dockerLogs, .dockerTop, .browser:
            completion([]) // utility/browser sessions are not fetched via tmux
            return
        }

        let (cmd, args) = appState.remoteCommand(script, host: host)

        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion([])
            return
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let parsed = Self.parseSessionList(output, source: source)
        for (session, activity) in parsed {
            guard let activity else { continue }
            TerminalActivityStore.shared.recordExternal(sessionID: session.id, at: activity)
        }

        completion(parsed.map(\.session))
    }

    /// Parse `tmux ls -F "#{session_name}|#{session_activity}"`.
    ///
    /// The delimiter is split off BEFORE the name is validated. The name
    /// rule rejects anything with a `|` or a digit-only tail, so
    /// validating the whole line would have rejected every session and
    /// silently emptied the list — the failure this codebase keeps
    /// finding the hard way.
    ///
    /// A tmux too old to know `session_activity` expands it to nothing,
    /// leaving "name|", which parses to a session with no timestamp. That
    /// degrades to the previous behavior rather than losing the session.
    static func parseSessionList(_ output: String,
                                 source: SessionSource) -> [(session: TmuxSession, activity: Date?)] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line -> (TmuxSession, Date?)? in
                let parts = line.split(separator: "|", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                let name = String(parts[0])
                guard !name.isEmpty, name.count < 100, !name.contains("  "),
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-"
                                        || $0 == "_" || $0 == "." || $0 == " " })
                else { return nil }

                var activity: Date?
                if parts.count > 1,
                   let epoch = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)),
                   epoch > 0 {
                    activity = Date(timeIntervalSince1970: epoch)
                }
                return (TmuxSession(name: name, source: source), activity)
            }
    }

    private func fetchDockerContainerSessions(host: HostConfig, completion: @escaping ([TmuxSession]) -> Void) {
        let listScript = "docker ps --format \"{{.Names}}\" 2>/dev/null || true"
        let (cmd, args) = appState.remoteCommand(listScript, host: host)

        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion([])
            return
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let containerNames = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !containerNames.isEmpty else {
            completion([])
            return
        }

        var allDockerSessions: [TmuxSession] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for containerName in containerNames {
            group.enter()

            let source = SessionSource.docker(hostID: host.id, containerName: containerName)
            fetchTmuxSessions(host: host, source: source) { sessions in
                lock.lock()
                // Always add utility sessions for each container
                allDockerSessions.append(TmuxSession(
                    name: "logs",
                    source: .dockerLogs(hostID: host.id, containerName: containerName)
                ))
                allDockerSessions.append(TmuxSession(
                    name: "top",
                    source: .dockerTop(hostID: host.id, containerName: containerName)
                ))
                if !sessions.isEmpty {
                    allDockerSessions.append(contentsOf: sessions)
                }
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        completion(allDockerSessions)
    }

    // MARK: - Session Switching

    func switchToSession(_ session: TmuxSession) {
        rapidDeaths = 0
        stopPairRecoveryWait()
        lastStartTime = Date()
        isKeySetup = false

        DispatchQueue.main.async {
            self.appState.activeSession = session
        }
        // Fresh chance for this session — its state is re-derived from the
        // spawn below (or stays live if the pooled process is running).
        clearSessionState(for: session.id)

        // If the pooled view already has a running process, instant switch
        if let entry = pool[session.id], entry.processRunning {
            activateSession(session)
            return
        }

        // Paused host — show the reminder instead of spawning ssh.
        if let host = appState.host(for: session.source.hostID), host.paused {
            setSessionState(.hostPaused(hostLabel: host.label), for: session.id)
            clearPendingStatus(for: session.id)
            destroyPoolEntry(session.id)
            activateSession(session)
            return
        }

        // Dead or missing session — destroy stale entry so we get a fresh terminal
        setPendingStatus(.connecting, for: session)
        destroyPoolEntry(session.id)
        let tv = activateSession(session)

        let (cmd, args) = appState.commandForSession(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
            self.pool[session.id]?.processRunning = true
            TerminalActivityStore.shared.markConnected(sessionID: session.id)
            self.setSessionState(.connected, for: session.id)
            self.clearPendingStatus(for: session.id)
            self.publishPoolStatus()
        }
    }

    func createNewTmuxSession(_ session: TmuxSession) {
        // Claim a ⌘-number for it while there's one free, so keyboard
        // switching works before the user has met the favorites system.
        DispatchQueue.main.async { self.appState.autoFavoriteNewSession(session) }
        rapidDeaths = 0
        stopPairRecoveryWait()
        lastStartTime = Date()
        isKeySetup = false

        // Can't create a session on a host we're not allowed to talk to.
        if let host = appState.host(for: session.source.hostID), host.paused {
            DispatchQueue.main.async {
                self.appState.allSessions.append(session)
                self.appState.activeSession = session
            }
            setSessionState(.hostPaused(hostLabel: host.label), for: session.id)
            activateSession(session)
            return
        }

        // Register in topology store immediately so it survives re-enumeration
        NetworkTopologyStore.shared.mergeEnumeration(
            hostID: session.source.hostID,
            sessions: [session],
            probeResult: .ok
        )

        DispatchQueue.main.async {
            self.appState.allSessions.append(session)
            self.appState.activeSession = session
        }
        clearSessionState(for: session.id)

        let tv = activateSession(session)
        let (cmd, args) = appState.commandForSession(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
            self.pool[session.id]?.processRunning = true
            TerminalActivityStore.shared.markConnected(sessionID: session.id)
            self.setSessionState(.connected, for: session.id)
        }
    }

    /// Light refresh: re-enumerate sessions without disrupting the current connection.
    /// Used after settings changes to detect new hosts and trigger key setup if needed.
    func softRefreshSessions() {
        enumerateAllSessions {}
    }

    /// Manual refresh: tear down and reconnect the active session
    func refreshActiveSession() {
        rapidDeaths = 0
        stopPairRecoveryWait()
        lastStartTime = Date()
        isKeySetup = false

        let targetSession = appState.activeSession
        setPendingStatus(.enumerating, for: targetSession)

        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }

        if let target = targetSession {
            clearSessionState(for: target.id)
        }

        enumerateAllSessions {
            DispatchQueue.main.async {
                if let target = targetSession {
                    self.appState.activeSession = target
                }
                // Only grab focus if the terminal still has it — the user may
                // have switched to another panel while waiting for the reconnect
                let shouldFocus = self.appState.focusedComponent == .terminal
                self.connectToActiveSession(grabFocus: shouldFocus)
            }
        }
    }

    /// Reconnect the active session through the connection pair.
    ///
    /// The old design probed the host itself and climbed an exponential
    /// backoff ladder (0.5s→30s, 8 attempts) — every terminal fighting
    /// its own private war against the network. Now the pair supervisor
    /// owns connectivity: if its active connection is usable, attaching
    /// is one mux channel request (~100ms, already authenticated), so we
    /// do it IMMEDIATELY with no probe and no backoff. If the pair is
    /// down, we wait for its recovery signal — the pair is already
    /// retrying on its own cadence; a terminal retrying on top of that
    /// was the reconnect storm.
    func reconnect() {
        guard let target = appState.activeSession else { return }

        // Paused host: there is nothing to reconnect to, by the user's own
        // instruction. Say so and stop — no recovery wait, no retries.
        if let host = appState.host(for: target.source.hostID), host.paused {
            stopPairRecoveryWait()
            setSessionState(.hostPaused(hostLabel: host.label), for: target.id)
            clearPendingStatus(for: target.id)
            return
        }

        // The session's process is dead — publish that truth immediately.
        // This is what gates keyboard input and shows the overlay, so it
        // is tied to actual process death, never to scheduling details.
        setSessionState(.reattaching(reason: "connection lost", since: Date()), for: target.id)

        guard let host = appState.host(for: target.source.hostID), !host.isLocal else {
            // Local session — nothing to wait for; just respawn.
            performReconnect(targetSession: target)
            return
        }

        let health = ConnectionPairRegistry.shared.health(for: host)
        if health.state.isUsable {
            // The remote is reachable and answering — if the session
            // still dies instantly over and over, the session command
            // itself is being rejected. Surface it, but DON'T dead-end:
            // the auto-heal observer retries the moment the pair rolls a
            // fresh connection (generation change). The user should
            // never have to press ⌘K for a connection-level problem.
            if rapidDeaths >= maxRapidDeaths {
                failedGeneration[host.id] = health.generation
                setHostState(
                    .failed(error: "Session on \(host.label) keeps dying right after connect.\nRetrying automatically when the connection recycles — or ⌘K → Reconnect SSH to force it now."),
                    hostID: host.id
                )
                clearPendingStatus(for: target.id)
                return
            }
            setPendingStatus(.connecting, for: target)
            performReconnect(targetSession: target)
        } else {
            // Pair down/offline/sleeping — wait for its recovery.
            setPendingStatus(.reconnecting, for: target)
            beginPairRecoveryWait(target: target, host: host)
        }
    }

    /// Watch the pair's health until it recovers, then attach. The pair
    /// does all the actual retrying — this just watches, FOREVER. There
    /// is deliberately no deadline: the old 120s → .failed dead-end
    /// meant a long outage parked the terminal in a state that waited
    /// for the user to press ⌘K — the exact opposite of "come to my
    /// desk and it works". If the host is down for six hours, the
    /// moment it's back the terminal reattaches on its own.
    private func beginPairRecoveryWait(target: TmuxSession, host: HostConfig) {
        guard recoveryWaitTimer == nil else { return }  // already waiting
        recoveryWaitStart = Date()
        recoveryWaitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            // User switched away — don't fight their choice.
            if self.appState.activeSession?.id != target.id {
                self.stopPairRecoveryWait()
                self.clearSessionState(for: target.id)
                self.clearPendingStatus(for: target.id)
                return
            }

            // Host paused mid-wait — stop watching and say why.
            if self.appState.hostIsPaused(host.id) {
                self.stopPairRecoveryWait()
                self.setSessionState(.hostPaused(hostLabel: host.label), for: target.id)
                self.clearPendingStatus(for: target.id)
                return
            }

            let health = ConnectionPairRegistry.shared.health(for: host)
            if health.state.isUsable {
                self.stopPairRecoveryWait()
                self.rapidDeaths = 0
                self.performReconnect(targetSession: target)
            }
        }
    }

    func stopPairRecoveryWait() {
        recoveryWaitTimer?.invalidate()
        recoveryWaitTimer = nil
        recoveryWaitStart = nil
    }

    /// Actually reconnect once the pair is usable (or the session is
    /// local). Directly reconnects the target session without full
    /// re-enumeration — enumeration is slow and itself can fail, making
    /// reconnect worse.
    private func performReconnect(targetSession: TmuxSession?) {
        // Session state stays .reattaching here — the truth is that the
        // process is still dead. connectToActiveSession publishes .connected
        // only after it actually starts the new process.
        self.lastStartTime = Date()

        // Destroy the dead entry so we get a fresh terminal view
        if let id = self.activeSessionID {
            self.destroyPoolEntry(id)
            self.activeSessionID = nil
        }

        // Short beat for SwiftTerm's IO teardown to drain. (The old 1s
        // "let sshd release the slot" delay is gone — a mux channel
        // attach doesn't consume a connection slot at all.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // Only restore the target session if the user hasn't switched away
            // during the delay. Overwriting a user's explicit session switch is wrong.
            if let target = targetSession {
                let currentID = self.appState.activeSession?.id
                if currentID == nil || currentID == target.id {
                    self.appState.activeSession = target
                } else {
                    print("performReconnect: user switched to \(currentID ?? "nil"), not restoring \(target.id)")
                    // Not reattaching this session anymore — drop its state.
                    self.clearSessionState(for: target.id)
                    return // user switched — don't reconnect the old session
                }
            }
            // Restore focus to the reconnected terminal if it was focused
            // before the drop (same as reload/tab-switch), with staggered
            // retries to survive the new view's layout/process-start race.
            let shouldFocus = self.appState.focusedComponent == .terminal
            self.connectToActiveSession(grabFocus: shouldFocus, isReconnect: true)
            if shouldFocus { self.restoreFocus() }
        }
    }
}
