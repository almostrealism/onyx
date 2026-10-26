//
// AppState+PaneLookup.swift
//
// Responsibility: The SSH half of naming a Claude session's tmux session
//                 when its hooks couldn't (see TmuxPaneLookup): pick the
//                 host the hook came from and ask its tmux for the panes.
// Scope: App-wide. ClaudeSessionManager calls it; the first window wires it.
//

import Foundation
import OnyxCore

extension AppState {

    /// Hand ClaudeSessionManager a way to ask hosts about their panes.
    func registerPaneLookup() {
        ClaudeSessionManager.shared.registerPaneLookup(owner: self) { [weak self] origin, done in
            guard let self else { return done(nil) }
            self.lookUpPaneSession(origin, done: done)
        }
    }

    /// Ask the hosts that could be `origin.machine` which tmux session its
    /// pids are in. Hosts named like the machine are asked first; when none
    /// is, every reachable host is asked and only a single hit is believed —
    /// a pid means nothing on the wrong machine, and a host configured by
    /// IP address or ssh alias carries no name to match.
    func lookUpPaneSession(_ origin: HookOrigin, done: @escaping (String?) -> Void) {
        let localName = Self.shortHostName()
        let usable = hosts.filter { !$0.paused && hostUsable($0) }
        let named = usable.filter { host in
            host.isLocal ? localName.caseInsensitiveCompare(origin.machine) == .orderedSame
                         : TmuxPaneLookup.hostCouldBe(host.ssh.host, machine: origin.machine)
        }
        let candidates = named.isEmpty ? usable.filter { !$0.isLocal } : named
        guard !candidates.isEmpty else { return done(nil) }

        // Build the commands here, where AppState lives; run them off main.
        let jobs: [(label: String, piped: (cmd: String, args: [String], stdin: String?),
                    tty: (cmd: String, args: [String], stdin: String?), release: () -> Void)]
            = candidates.compactMap { host in
                guard let release = acquireUtilityChannel("tmux-panes", host: host) else { return nil }
                let tty = remoteScript(TmuxPaneLookup.script, host: host)
                let piped = host.isLocal ? tty : remoteScriptNoTTY(TmuxPaneLookup.script, host: host)
                return (host.label, piped, tty, release)
            }
        guard !jobs.isEmpty else { return done(nil) }
        let trustSingleOnly = named.isEmpty

        DispatchQueue.global(qos: .utility).async {
            var hits: [String] = []
            for job in jobs {
                defer { job.release() }
                let run = FileBrowserManager.runScriptWithFallback(piped: job.piped, tty: job.tty,
                                                                   label: job.label, timeout: 8)
                guard let output = run.cleaned,
                      let name = TmuxPaneLookup.session(ancestors: origin.pids,
                                                        panes: TmuxPaneLookup.parse(output)) else { continue }
                hits.append(name)
                if !trustSingleOnly { break }
            }
            done(trustSingleOnly && hits.count != 1 ? nil : hits.first)
        }
    }

    /// This Mac's short hostname, as the bridge reports it.
    static func shortHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        let name = String(cString: buffer)
        return name.split(separator: ".").first.map(String.init) ?? name
    }
}
