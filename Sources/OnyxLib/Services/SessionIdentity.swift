//
// SessionIdentity.swift
//
// Responsibility: The key under which a session's note and favourite are
//                 STORED — as opposed to `SessionSource.stableKey`, which
//                 identifies a session within one running app.
// Scope: Service. Pure functions over HostConfig; no state, no I/O.
//
// Why the two differ. In memory, a host is a UUID from hosts.json and
// that's unambiguous. On disk it's useless: the same machine has a
// different UUID on your other Mac, and even on this one, deleting a
// host in Settings and adding it back loses every note attached to it.
// A stored key has to name something both machines agree on.
//
// It names user AND host, because tmux sessions are per-user: log in as
// someone else on the same machine and `tmux ls` shows a different set.
// Keying by host alone would merge two people's sessions under one note.
//
// The host is as WE address it, never what the machine calls itself.
// Asking the remote for its hostname would let a host claim to be
// another one and inherit its notes, which is a bad trade for tidiness.
// The cost is that two routes to one machine (an alias, an IP, a
// tunnel) read as two machines — visible and explainable, unlike the
// alternative.
//

import Foundation

public enum SessionIdentity {

    /// The user we will actually connect as.
    ///
    /// An empty `ssh.user` means ssh uses the LOCAL account name — so on
    /// a laptop where you're `michael` and a desktop where you're
    /// `worker`, an unspecified user is genuinely two different remote
    /// users with two different sets of tmux sessions. Resolving it here
    /// keeps those apart rather than pretending they're one.
    public static func effectiveUser(for host: HostConfig,
                                     localUser: String = NSUserName()) -> String {
        let configured = host.ssh.user.trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? localUser : configured
    }

    /// The host as this machine addresses it.
    ///
    /// Lower-cased and trimmed, with a trailing dot removed (an FQDN's
    /// root label is invisible to the user and would otherwise split
    /// `build.example.com.` from `build.example.com`). Nothing else is
    /// normalised: `.local` names and IPs stay as typed, because
    /// "whatever we see it as from here" is the whole rule.
    public static func normalizedHost(for host: HostConfig) -> String {
        if host.isLocal { return "localhost" }
        var h = host.ssh.host.trimmingCharacters(in: .whitespaces).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? "localhost" : h
    }

    /// `user@host` — the stored identity of a machine-and-account.
    public static func key(for host: HostConfig, localUser: String = NSUserName()) -> String {
        "\(effectiveUser(for: host, localUser: localUser))@\(normalizedHost(for: host))"
    }

    /// The storage key for one session.
    ///
    /// Mirrors `SessionSource.stableKey`'s shape so the two read alike,
    /// with the machine identity in place of the local UUID.
    public static func storageKey(for session: TmuxSession, host: HostConfig,
                                  localUser: String = NSUserName()) -> String {
        let machine = key(for: host, localUser: localUser)
        switch session.source {
        case .host:
            return "host:\(machine):\(session.name)"
        case .docker(_, let container):
            return "docker:\(machine):\(container):\(session.name)"
        case .dockerLogs(_, let container):
            return "dockerlogs:\(machine):\(container):\(session.name)"
        case .dockerTop(_, let container):
            return "dockertop:\(machine):\(container):\(session.name)"
        case .browser(let url):
            // A browser tab isn't on a machine at all.
            return "browser:\(url):\(session.name)"
        }
    }

    /// Rewrite a UUID-keyed storage key into a machine-keyed one.
    ///
    /// Returns nil when the key doesn't mention a host we know about —
    /// a note for a host that has since been deleted. Those are LEFT
    /// ALONE rather than dropped: someone may re-add the host, and
    /// silently discarding notes during a migration is unforgivable.
    public static func migrate(storageKey old: String, hosts: [HostConfig],
                               localUser: String = NSUserName()) -> String? {
        let byUUID = Dictionary(hosts.map { ($0.id.uuidString, $0) },
                                uniquingKeysWith: { first, _ in first })
        let parts = old.components(separatedBy: ":")
        guard parts.count >= 3 else { return nil }

        // Already migrated: the second field is user@host, not a UUID.
        if parts[1].contains("@") { return nil }
        guard let host = byUUID[parts[1]] else { return nil }

        var rebuilt = parts
        rebuilt[1] = key(for: host, localUser: localUser)
        return rebuilt.joined(separator: ":")
    }
}
