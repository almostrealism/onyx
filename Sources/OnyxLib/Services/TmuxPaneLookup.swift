//
// TmuxPaneLookup.swift
//
// Responsibility: Finding which tmux session a Claude session runs in when
//                 its hooks couldn't say — from the ancestor pids the hook
//                 sent and the pane list of the host's tmux server.
// Scope: Stateless; the script, its parser and the match.
//
// The case: you SSH in as one account, open tmux, and `su - other` to run
// Claude. `su -` clears TMUX, and the tmux server's socket belongs to the
// first account, so the hook can't ask tmux anything. But Onyx connects as
// the first account, and the pane's shell is one of the hook's ancestors:
// `tmux list-panes -a` gives each pane's shell pid, and the nearest
// ancestor that is one of them names the session.
//

import Foundation

public enum TmuxPaneLookup {

    /// Every pane on the host's default tmux server: "<pane pid> <session>".
    /// No `!` and no glob, for the interactive fallback (see CLAUDE.md).
    /// A host without tmux, or without a server, prints nothing.
    public static let script = "tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null"

    /// Pane shell pid → session name, from the script's output. Lines that
    /// aren't "<number> <name>" (a login banner, the TTY echo) are skipped.
    public static func parse(_ output: String) -> [Int: String] {
        var panes: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int(parts[0]), pid > 1 else { continue }
            panes[pid] = String(parts[1])
        }
        return panes
    }

    /// The session of the nearest ancestor that is a pane's shell.
    public static func session(ancestors: [Int], panes: [Int: String]) -> String? {
        for pid in ancestors { if let name = panes[pid] { return name } }
        return nil
    }

    /// Whether `host` (as configured) can be the machine a hook named.
    /// The hook sends its short hostname; the config may say
    /// "mac-studio", "mac-studio.local" or a full DNS name.
    public static func hostCouldBe(_ configured: String, machine: String) -> Bool {
        let a = configured.lowercased(), m = machine.lowercased()
        guard !a.isEmpty, !m.isEmpty else { return false }
        return AlertRouting.hostMatches(a, m)
    }
}
