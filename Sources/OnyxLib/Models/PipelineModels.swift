import Foundation

/// A pipeline the user wants to track — either a workflow definition
/// (always look at the latest run on a given branch) or a single
/// locked-in run identified by ID.
public struct PipelineSpec: Equatable, Hashable {
    public let url: String        // verbatim URL the user pasted
    public let provider: GitProvider
    /// Full project path: "owner/repo" (GitHub) or "group/[sub/]project"
    /// (GitLab). GitHub paths are always two segments.
    public let path: String
    public let target: Target

    public enum Target: Equatable, Hashable {
        /// Latest run of `file` on `branch`. `branch == nil` means the
        /// repo's default branch. (GitHub)
        case workflow(file: String, branch: String?)
        /// A specific, frozen workflow run. (GitHub)
        case run(id: Int)
        /// A specific, frozen GitLab pipeline.
        case pipeline(id: Int)
    }

    public init(url: String, provider: GitProvider = .github,
                path: String, target: Target) {
        self.url = url; self.provider = provider; self.path = path; self.target = target
    }

    /// Back-compat convenience for GitHub owner/repo construction.
    public init(url: String, owner: String, repo: String, target: Target) {
        self.init(url: url, provider: .github, path: "\(owner)/\(repo)", target: target)
    }

    /// First path segment — the GitHub owner. (GitHub REST URLs need it.)
    public var owner: String { path.split(separator: "/").first.map(String.init) ?? path }
    /// Last path segment — the GitHub repo / GitLab project leaf.
    public var repo: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// URL-encoded full path for the GitLab REST API (`/projects/:id`).
    public var encodedPath: String {
        path.addingPercentEncoding(withAllowedCharacters: GitLabPath.allowed) ?? path
    }

    public var fullName: String { path }

    public var displayName: String {
        switch target {
        case .workflow(let file, let branch):
            let stem = (file as NSString).deletingPathExtension
            if let b = branch, b != "main", b != "master" {
                return "\(stem) (\(b))"
            }
            return stem
        case .run(let id):
            return "run #\(id)"
        case .pipeline(let id):
            return "pipeline #\(id)"
        }
    }

    /// Stable identifier used for SwiftUI lists + dedupe checks.
    public var id: String {
        switch target {
        case .workflow(let file, let branch):
            return "\(provider.rawValue):\(path)/wf/\(file)/\(branch ?? "*")"
        case .run(let id):
            return "\(provider.rawValue):\(path)/run/\(id)"
        case .pipeline(let id):
            return "\(provider.rawValue):\(path)/pipeline/\(id)"
        }
    }

    /// Parse any github.com or gitlab.com pipeline URL the user might
    /// paste. GitHub: workflow-file or run URL (optionally `?branch=…`).
    /// GitLab: a `/-/pipelines/<id>` URL. The provider is detected from
    /// the host and recorded on the spec so the right manager handles it.
    public static func parse(_ raw: String) -> PipelineSpec? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let gitlab = parseGitLab(s) { return gitlab }
        return parseGitHub(s)
    }

    private static func parseGitHub(_ raw: String) -> PipelineSpec? {
        var s = raw

        // Strip protocol + host. Require github.com (or no host).
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
        }

        // Split off query string.
        var query = ""
        if let qIdx = s.firstIndex(of: "?") {
            query = String(s[s.index(after: qIdx)...])
            s = String(s[..<qIdx])
        }
        // Strip trailing slash.
        if s.hasSuffix("/") { s = String(s.dropLast()) }

        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        if owner.contains(".") || repo.contains(".") { return nil }  // not github

        // Extract a branch from `?branch=foo` or `?query=branch%3Afoo`
        // (GitHub's own actions UI uses the latter).
        let branch: String? = {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let value = kv[1].removingPercentEncoding ?? kv[1]
                if kv[0] == "branch" { return value }
                if kv[0] == "query", value.hasPrefix("branch:") {
                    return String(value.dropFirst("branch:".count))
                }
            }
            return nil
        }()

        // /actions/workflows/<file> → workflow target
        // /actions/runs/<id>        → run target
        if parts.count >= 5, parts[2] == "actions" {
            if parts[3] == "workflows" {
                return PipelineSpec(
                    url: raw, owner: owner, repo: repo,
                    target: .workflow(file: parts[4], branch: branch)
                )
            }
            if parts[3] == "runs", let id = Int(parts[4]) {
                return PipelineSpec(
                    url: raw, owner: owner, repo: repo,
                    target: .run(id: id)
                )
            }
        }
        return nil
    }

    /// GitLab: `https://gitlab.com/group/[sub/]project/-/pipelines/<id>`.
    /// The project path is everything before the `/-/` marker; the
    /// pipeline id is the trailing segment.
    private static func parseGitLab(_ raw: String) -> PipelineSpec? {
        var s = raw
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
        } else {
            return nil   // GitLab requires an explicit host to disambiguate
        }

        // Drop any query/fragment.
        if let qIdx = s.firstIndex(of: "?") { s = String(s[..<qIdx]) }

        guard let r = s.range(of: "/-/") else { return nil }
        let path = String(s[..<r.lowerBound])
        let rest = s[r.upperBound...].split(separator: "/").map(String.init)
        guard !path.isEmpty,
              rest.count >= 2, rest[0] == "pipelines",
              let id = Int(rest[1]) else { return nil }
        return PipelineSpec(url: raw, provider: .gitlab, path: path,
                            target: .pipeline(id: id))
    }
}

/// Aggregated job counts + overall state for a single tracked pipeline.
public struct PipelineStatus: Identifiable, Equatable {
    public var id: String { spec.id }
    public var provider: GitProvider { spec.provider }
    public let spec: PipelineSpec
    public let runNumber: Int?
    public let runURL: String?
    public let headBranch: String?
    public let title: String?
    public let succeeded: Int
    public let inProgress: Int
    public let queued: Int
    public let skipped: Int
    public let failed: Int
    public let overall: PipelineOverallStatus
    public let lastUpdated: Date

    public init(spec: PipelineSpec, runNumber: Int?, runURL: String?,
                headBranch: String?, title: String?,
                succeeded: Int, inProgress: Int, queued: Int,
                skipped: Int, failed: Int,
                overall: PipelineOverallStatus, lastUpdated: Date) {
        self.spec = spec; self.runNumber = runNumber; self.runURL = runURL
        self.headBranch = headBranch; self.title = title
        self.succeeded = succeeded; self.inProgress = inProgress
        self.queued = queued; self.skipped = skipped; self.failed = failed
        self.overall = overall; self.lastUpdated = lastUpdated
    }
}

public enum PipelineOverallStatus: String, Equatable {
    case running        // at least one in-progress job, no failures
    case success        // all completed cleanly
    case failure        // at least one failed
    case mixed          // both failures and successes; deserves attention
    case queued         // hasn't started yet
    case skipped        // pipeline as a whole was skipped
    case unknown

    /// Roll per-bucket job counts up into one overall state. Shared by
    /// the GitHub (WorkflowMonitor) and GitLab (GitLabPipelineMonitor)
    /// pollers so both read the same way. `totalJobs` distinguishes an
    /// empty pipeline (→ .unknown) from one that's genuinely all-success.
    public static func derive(succeeded: Int, inProgress: Int, queued: Int,
                              skipped: Int, failed: Int, totalJobs: Int)
        -> PipelineOverallStatus {
        if failed > 0 && succeeded > 0 { return .mixed }
        if failed > 0 { return .failure }
        if inProgress > 0 { return .running }
        if queued > 0 && succeeded == 0 { return .queued }
        if totalJobs == 0 { return .unknown }
        if skipped > 0 && succeeded == 0 && failed == 0 { return .skipped }
        return .success
    }
}
