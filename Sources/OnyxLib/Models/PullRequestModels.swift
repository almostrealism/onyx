import Foundation

/// One open PR surfaced by the monitor overlay. Polled from the GitHub
/// GraphQL API by `PullRequestManager` and rendered by
/// `PullRequestsSection`.
public struct PullRequest: Identifiable, Equatable, Hashable {
    /// "owner/repo#123" — stable across polls so SwiftUI doesn't churn.
    public var id: String { "\(repoFullName)#\(number)" }
    public let repoFullName: String   // "owner/repo"
    public let number: Int
    public let title: String
    public let url: String
    /// Number of review threads still marked as unresolved on the PR.
    /// A reasonable proxy for "how much discussion is still open here".
    public let openCommentThreads: Int
    /// Whether the PR is currently merge-ready per the repo's rules.
    /// Derived from GraphQL's `mergeStateStatus` — CLEAN means passes
    /// branch protections + no conflicts + checks green.
    public let mergeStatus: PRMergeStatus

    public init(repoFullName: String, number: Int, title: String, url: String,
                openCommentThreads: Int, mergeStatus: PRMergeStatus) {
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.url = url
        self.openCommentThreads = openCommentThreads
        self.mergeStatus = mergeStatus
    }
}

/// Simplified mergeable state. Maps from GitHub's `mergeStateStatus`:
///   CLEAN          → .ready
///   BEHIND         → .behind  (just needs rebase / merge of base)
///   BLOCKED        → .blocked (failing checks, missing reviews, etc.)
///   DIRTY          → .conflicts
///   UNSTABLE       → .checksFailing
///   HAS_HOOKS      → .ready (passes everything visible to us)
///   UNKNOWN        → .unknown
public enum PRMergeStatus: String, Codable, Equatable {
    case ready          // can merge now
    case behind         // out of date with base
    case blocked        // branch protections / reviews not satisfied
    case conflicts      // merge conflicts
    case checksFailing  // tests/CI failing
    case unknown        // GitHub hasn't decided yet (PR is fresh)
}

/// One configured repo to watch — the URL the user pasted in settings,
/// plus parsed owner/name.
public struct GitHubRepoSpec: Equatable, Hashable {
    public let url: String
    public let owner: String
    public let name: String

    public var fullName: String { "\(owner)/\(name)" }

    public init(url: String, owner: String, name: String) {
        self.url = url; self.owner = owner; self.name = name
    }

    /// Parse "https://github.com/foo/bar", "github.com/foo/bar",
    /// "foo/bar", "https://github.com/foo/bar.git" — all into the
    /// canonical owner/name pair. Returns nil for any input that isn't
    /// recognizable as a github.com path. Non-github hosts (gitlab,
    /// bitbucket, etc.) are explicitly rejected so we never try to hit
    /// the GitHub API with the wrong owner.
    public static func parse(_ raw: String) -> GitHubRepoSpec? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // A URL with a protocol must be a github.com URL.
        if let r = s.range(of: "://") {
            let tail = String(s[r.upperBound...])
            if tail.hasPrefix("github.com/") {
                s = String(tail.dropFirst("github.com/".count))
            } else if tail.hasPrefix("www.github.com/") {
                s = String(tail.dropFirst("www.github.com/".count))
            } else {
                return nil
            }
        } else if s.hasPrefix("github.com/") {
            s = String(s.dropFirst("github.com/".count))
        } else if s.hasPrefix("www.github.com/") {
            s = String(s.dropFirst("www.github.com/".count))
        }

        // No-protocol input with a "." in the first segment isn't a
        // github path — likely another host's bare URL (gitlab.com/...).
        let firstSegment = s.split(separator: "/").first.map(String.init) ?? ""
        if firstSegment.contains(".") { return nil }

        // Trim trailing junk.
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return GitHubRepoSpec(url: raw, owner: parts[0], name: parts[1])
    }
}
