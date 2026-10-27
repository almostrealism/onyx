//
// TmuxSessions.swift
//
// Responsibility: Listing a host's tmux sessions and attaching to one —
//                 the script, the parser, and the names that are safe to
//                 put in a command line. Shared by the Mac's session
//                 enumeration and the iPad's sidebar.
// Scope: Service. Pure functions.
//

import Foundation

public enum TmuxSessions {

    /// `tmux ls` with each session's name and tmux's own unix timestamp of
    /// its last activity — the idle indicator's question, answered by the
    /// command we were running anyway. Empty output (no server) is fine.
    public static func listScript(container: String? = nil) -> String {
        let ls = "tmux ls -F \"#{session_name}|#{session_activity}\" 2>/dev/null || true"
        guard let container else { return ls }
        return "docker exec \(safeContainer(container)) \(ls)"
    }

    /// Parse `listScript`'s output. Lines that can't be a session name —
    /// a login banner, a shell's complaint — are dropped.
    public static func parse(_ output: String,
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

    /// The command a terminal runs to reach `name`: attach, or create it.
    /// Ride it on an exec request (`RemoteWire.execCommand`), which adds
    /// the login shell and the PATH tmux usually lives on. `-u`: the
    /// client draws UTF-8 — an exec session often has no locale set, and
    /// tmux would otherwise turn every "—" into "_".
    public static func attachCommand(_ name: String) -> String {
        "tmux -u new-session -A -s \(safeSession(name))"
    }

    /// A session name safe to interpolate: letters, digits, - and _.
    public static func safeSession(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    /// A container name safe to interpolate: also dots.
    public static func safeContainer(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }
}
