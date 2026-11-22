//
// TerminalSessionManager+Tmux.swift
//
// Responsibility: A host without tmux — noticing it, saying so, and
//                 installing tmux there in a terminal the user can watch
//                 (and type a sudo password into).
// Scope: Per-window terminal manager (OnyxTerminalView), like key setup.
//
// The signal is an attach that exits 127 ("command not found") right
// after it starts. Only then do we spend an ssh call on the probe, so a
// healthy host never pays for this. Container sessions are left out: a
// 127 there could be docker or the container's tmux, and installing into
// a container doesn't survive it being recreated.
//

import AppKit
import OnyxCore

extension OnyxTerminalView {

    /// The exit code a shell gives a command it can't find.
    static let commandNotFound: Int32 = 127

    /// A session died instantly with 127: find out whether the host has
    /// tmux before spending reconnect attempts on it. Returns false when
    /// this doesn't apply, and the caller carries on as before.
    func checkForTmuxAfterInstantDeath(of session: TmuxSession, exitCode: Int32?) -> Bool {
        guard exitCode == Self.commandNotFound,
              case .host(let hostID) = session.source,
              let host = appState.host(for: hostID) else { return false }

        setSessionState(.reattaching(reason: "checking for tmux", since: Date()), for: session.id)
        let transport = appState.transport
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let run = transport.runScript(TmuxInstall.probeScript, on: host, label: "tmux-check")
            let probe = run.cleaned.flatMap(TmuxInstall.parse)
            DispatchQueue.main.async {
                guard let self else { return }
                // The user may have moved on while we asked.
                guard self.appState.activeSession?.id == session.id else { return }
                if let probe, !probe.present {
                    OnyxLog.session.notice("\(host.label, privacy: .public) has no tmux — offering to install it")
                    let plan = TmuxInstall.plan(for: probe, hostID: host.id, hostLabel: host.label)
                    self.showTmuxMissing(plan, session: session)
                } else {
                    // tmux is there (or the probe couldn't tell): the 127
                    // was something else. The usual path, with its cap.
                    self.reconnect()
                }
            }
        }
        return true
    }

    func showTmuxMissing(_ plan: TmuxInstallPlan, session: TmuxSession) {
        setHostState(.tmuxMissing(plan), hostID: plan.hostID)
        setSessionState(.tmuxMissing(plan), for: session.id)
    }

    /// Run the plan's install in a terminal of its own, in front, as key
    /// setup does. Its exit decides what's next (`tmuxInstallEnded`).
    func startTmuxInstall(_ plan: TmuxInstallPlan) {
        guard let host = appState.host(for: plan.hostID),
              let (cmd, args) = appState.tmuxInstallCommand(host: host, plan: plan) else { return }

        isTmuxInstall = true
        tmuxInstallPlan = plan
        rapidDeaths = 0
        stopPairRecoveryWait()
        lastStartTime = Date()

        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }
        let tv = createTerminalView()
        addSubview(tv)
        let key = "__tmux_install__"
        pool[key] = PoolEntry(terminalView: tv, lastActiveTime: Date(), processRunning: true)
        activeSessionID = key

        // Off with the overlay, so the install can be watched and typed into.
        for session in appState.allSessions where session.source.hostID == plan.hostID {
            clearSessionState(for: session.id)
        }
        if let active = appState.activeSession { clearSessionState(for: active.id) }

        tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.window?.makeFirstResponder(tv)
        }
    }

    /// The install terminal exited. 0 means the script found tmux
    /// afterwards: connect, as if nothing had happened. Anything else:
    /// back to the overlay, saying the attempt didn't take.
    func tmuxInstallEnded(exitCode: Int32?) {
        let plan = tmuxInstallPlan
        tmuxInstallPlan = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let id = self.activeSessionID {
                self.destroyPoolEntry(id)
                self.activeSessionID = nil
            }
            self.rapidDeaths = 0
            if exitCode == 0 {
                OnyxLog.session.notice("tmux installed on \(plan?.hostLabel ?? "?", privacy: .public)")
                self.enumerateAllSessions(then: {
                    self.connectToActiveSession()
                })
            } else if var plan, let session = self.appState.activeSession {
                plan.lastAttemptFailed = true
                self.showTmuxMissing(plan, session: session)
            }
        }
    }
}
