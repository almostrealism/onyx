import Foundation

/// One open PR surfaced by the monitor overlay. Polled from the GitHub
/// GraphQL API by `PullRequestManager` and rendered by
/// `PullRequestsSection`.
public struct PullRequest: Identifiable, Equatable, Hashable {
    /// "github:owner/repo#123" — provider-qualified so GitHub and GitLab
    /// items never collide in the merged list, and stable across polls so
    /// SwiftUI doesn't churn.
    public var id: String { "\(provider.rawValue):\(repoFullName)#\(number)" }
    /// Which forge this PR/MR lives on.
    public let provider: GitProvider
    public let repoFullName: String   // "owner/repo" (GitHub) or "group/project" (GitLab)
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
    /// Head branch (`headRefName`). Used to build pipeline-suggestion
    /// URLs for the "add pipeline from open PR" UX — we need the
    /// branch to query the latest workflow run on it.
    public let headBranch: String?
    /// Author login/username. Lets the "only mine" filter work and is
    /// shown nowhere directly, but kept for filtering robustness.
    public let author: String?

    public init(provider: GitProvider = .github,
                repoFullName: String, number: Int, title: String, url: String,
                openCommentThreads: Int, mergeStatus: PRMergeStatus,
                headBranch: String? = nil, author: String? = nil) {
        self.provider = provider
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.url = url
        self.openCommentThreads = openCommentThreads
        self.mergeStatus = mergeStatus
        self.headBranch = headBranch
        self.author = author
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

/// One configured GitLab project to watch for merge requests. GitLab
/// projects live at an arbitrary-depth path (group/subgroup/project), so
/// unlike GitHub we keep the whole path rather than an owner/name pair —
/// the REST API takes the URL-encoded full path as the project id.
public struct GitLabProjectSpec: Equatable, Hashable {
    public let url: String
    /// Full project path, e.g. "group/project" or "group/sub/project".
    public let path: String

    /// "project" — last path segment, for compact display.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// URL-encoded path for the REST API (`/projects/:id`).
    public var encodedPath: String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }

    public init(url: String, path: String) {
        self.url = url; self.path = path
    }

    /// Parse "https://gitlab.com/group/project", "gitlab.com/group/sub/project",
    /// or a bare "group/project". A leading `https://host` must be
    /// gitlab.com. Bare paths are accepted (the GitLab settings field
    /// disambiguates intent). Anything with a `/-/` segment (a deep link
    /// into the project) is trimmed back to the project path.
    public static func parse(_ raw: String) -> GitLabProjectSpec? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let r = s.range(of: "://") {
            let tail = String(s[r.upperBound...])
            if tail.hasPrefix("gitlab.com/") {
                s = String(tail.dropFirst("gitlab.com/".count))
            } else if tail.hasPrefix("www.gitlab.com/") {
                s = String(tail.dropFirst("www.gitlab.com/".count))
            } else {
                return nil
            }
        } else if s.hasPrefix("gitlab.com/") {
            s = String(s.dropFirst("gitlab.com/".count))
        }

        // Trim a deep link (…/-/merge_requests, …/-/pipelines, …) down to
        // the project path that precedes the "/-/" marker.
        if let r = s.range(of: "/-/") {
            s = String(s[..<r.lowerBound])
        }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return GitLabProjectSpec(url: raw, path: parts.joined(separator: "/"))
    }
}
