//
// SessionAlert.swift
//
// Responsibility: A message an agent sent to get the user's attention,
//                 and where it was aimed.
// Scope: Model. Pure data plus the routing rules, which are pure
//        functions over strings and therefore testable without an app.
//
// Deliberately not Apple-shaped. An alert carries two intentions —
// "this is urgent" and "tell me even if I'm not looking at Onyx" — and
// the platform decides how to honour them. On a Mac that happens to be
// dock bouncing and Notification Center; the tool says so, but the
// vocabulary stays about what the agent MEANS rather than what macOS
// does with it.
//

import Foundation

public struct SessionAlert: Identifiable, Codable, Equatable {
    public let id: UUID
    public let at: Date
    /// One line, shown in the list and in any OS notification.
    public let title: String
    /// Optional detail.
    public let body: String?
    /// Ask for attention beyond a quiet indicator. macOS: bounce the
    /// dock icon until Onyx is brought forward.
    public let urgent: Bool
    /// Deliver outside the app too, so it lands when Onyx isn't in
    /// front. macOS: Notification Center.
    public let external: Bool
    /// The session this is about, as a storage key, or nil when the
    /// agent didn't say (or we couldn't work it out).
    public let sessionKey: String?
    /// What the agent claimed, kept verbatim for display even when the
    /// session can't be matched — "waiting on tests / build-01 / me" is
    /// still useful when nothing resolves.
    public let target: Target?
    /// Cleared when the user opens the alert list for that session.
    public var seen: Bool

    public struct Target: Codable, Equatable {
        public let user: String?
        public let host: String?
        public let session: String?

        public init(user: String? = nil, host: String? = nil, session: String? = nil) {
            self.user = user
            self.host = host
            self.session = session
        }

        /// "me@build-01:trainer", for showing what was aimed at when the
        /// aim missed.
        public var label: String {
            let machine = [user, host].compactMap { $0 }.joined(separator: "@")
            return [machine, session ?? ""].filter { !$0.isEmpty }.joined(separator: ":")
        }
    }

    public init(id: UUID = UUID(), at: Date = Date(), title: String, body: String? = nil,
                urgent: Bool = false, external: Bool = false,
                sessionKey: String? = nil, target: Target? = nil, seen: Bool = false) {
        self.id = id
        self.at = at
        self.title = title
        self.body = body
        self.urgent = urgent
        self.external = external
        self.sessionKey = sessionKey
        self.target = target
        self.seen = seen
    }
}

public enum AlertRouting {

    /// Work out which session an alert is for.
    ///
    /// The agent may name a user, a host and a tmux session; it may name
    /// some of those; it may name none. A single unambiguous match is a
    /// match — if only one session on one host is called "trainer",
    /// naming the session alone is enough, and making the agent state
    /// all three would make the tool tedious for the common case.
    ///
    /// Ambiguity resolves to nil rather than to a guess: an alert on the
    /// wrong session is worse than an unattached one, because it lights
    /// an indicator next to work that isn't waiting on anything.
    public static func resolve(user: String?, host: String?, session: String?,
                               candidates: [(key: String, user: String, host: String, session: String)])
        -> String? {
        func norm(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !s.isEmpty else { return nil }
            return s
        }
        let wantUser = norm(user), wantHost = norm(host), wantSession = norm(session)
        guard wantUser != nil || wantHost != nil || wantSession != nil else { return nil }

        let matches = candidates.filter { c in
            if let u = wantUser, c.user.lowercased() != u { return false }
            if let h = wantHost, !hostMatches(c.host.lowercased(), h) { return false }
            if let s = wantSession, c.session.lowercased() != s { return false }
            return true
        }
        return matches.count == 1 ? matches[0].key : nil
    }

    /// A host is named loosely in practice — "build-01" for
    /// "build-01.example.com", or the other way round. Accept either
    /// direction of prefix match on a dot boundary, and nothing looser:
    /// "build" must not match "buildsomething".
    static func hostMatches(_ actual: String, _ wanted: String) -> Bool {
        if actual == wanted { return true }
        if actual.hasPrefix(wanted + ".") { return true }
        if wanted.hasPrefix(actual + ".") { return true }
        return false
    }
}
