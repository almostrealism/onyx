import Foundation

/// Character set for URL-encoding a GitLab project path into a REST
/// `/projects/:id` segment: only the slash (and other reserved chars)
/// get escaped; -._ and alphanumerics pass through, matching GitLab's
/// documented `group%2Fproject-client` form.
enum GitLabPath {
    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._")
        return set
    }()
}

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
    /// Whether this is a draft / work-in-progress.
    ///
    /// Comes from the API where the API knows (`isDraft` on GitHub,
    /// `draft` on GitLab) OR from the title, because plenty of teams mark
    /// drafts by convention on a PR the API considers ready. Either
    /// signal counts — a filter that hides "most" drafts is one you can't
    /// trust to hide any.
    public let isDraft: Bool
    /// Author login/username. Lets the "only mine" filter work and is
    /// shown nowhere directly, but kept for filtering robustness.
    public let author: String?

    /// Does this title announce a draft?
    ///
    /// Case-insensitive, and covers the three conventions in the wild:
    /// GitLab's own "Draft:" prefix, its legacy "WIP:" prefix, and the
    /// bracketed "[draft]" some teams use. Anchored to the start so a PR
    /// titled "remove draft: handling" isn't caught.
    public static func titleMarksDraft(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("draft:") || t.hasPrefix("draft :")
            || t.hasPrefix("[draft]") || t.hasPrefix("(draft)")
            || t.hasPrefix("wip:") || t.hasPrefix("[wip]")
    }

    public init(provider: GitProvider = .github,
                repoFullName: String, number: Int, title: String, url: String,
                openCommentThreads: Int, mergeStatus: PRMergeStatus,
                headBranch: String? = nil, author: String? = nil,
                apiSaysDraft: Bool = false) {
        // Either signal is enough: the API flag, or the title convention.
        self.isDraft = apiSaysDraft || Self.titleMarksDraft(title)
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
    /// Repository name, or empty when this entry means "every repo this
    /// owner has". Watching a whole org beats listing its repos one at a
    /// time and then missing the one someone created yesterday.
    public let name: String

    /// True when this entry is an owner or org rather than one repo.
    public var isOwnerWide: Bool { name.isEmpty }

    public var fullName: String { isOwnerWide ? owner : "\(owner)/\(name)" }

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
        guard let owner = parts.first, !owner.isEmpty else { return nil }
        // One segment = the whole owner ("almostrealism"); two = a single
        // repo ("almostrealism/common").
        guard parts.count >= 2 else {
            return GitHubRepoSpec(url: raw, owner: owner, name: "")
        }
        guard !parts[1].isEmpty else { return nil }
        return GitHubRepoSpec(url: raw, owner: owner, name: parts[1])
    }
}

/// One configured GitLab project to watch for merge requests. GitLab
/// projects live at an arbitrary-depth path (group/subgroup/project), so
/// unlike GitHub we keep the whole path rather than an owner/name pair —
/// the REST API takes the URL-encoded full path as the project id.
public struct GitLabProjectSpec: Equatable, Hashable {
    public let url: String
    /// Full project path, e.g. "group/project" or "group/sub/project" —
    /// or a group path ("fivn", "fivn/product_engineering"), which stands
    /// for every project under it, subgroups included.
    public let path: String

    /// Whether this path is definitely a group.
    ///
    /// A single segment can only be a group or user namespace — a project
    /// always lives under one. Deeper paths are genuinely ambiguous
    /// (`a/b` is a project in group `a`, OR subgroup `b` of group `a`),
    /// and nothing in the string can settle it; the manager resolves
    /// those by asking GitLab.
    public var isDefinitelyGroup: Bool {
        path.split(separator: "/").count == 1
    }

    /// "project" — last path segment, for compact display.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// URL-encoded path for the REST API (`/projects/:id`). GitLab's own
    /// docs encode only the slash (group%2Fproject-client), so we keep
    /// the common -._ path characters unescaped.
    public var encodedPath: String {
        path.addingPercentEncoding(withAllowedCharacters: GitLabPath.allowed) ?? path
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
        // One segment is a group ("fivn"), which stands for every project
        // under it. Two or more is a project path — or a subgroup, which
        // only GitLab can tell us.
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return GitLabProjectSpec(url: raw, path: parts.joined(separator: "/"))
    }
}
