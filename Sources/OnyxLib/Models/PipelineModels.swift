import Foundation

/// A pipeline the user wants to track — either a workflow definition
/// (always look at the latest run on a given branch) or a single
/// locked-in run identified by ID.
public struct PipelineSpec: Equatable, Hashable {
    public let url: String        // verbatim URL the user pasted
    public let owner: String
    public let repo: String
    public let target: Target

    public enum Target: Equatable, Hashable {
        /// Latest run of `file` on `branch`. `branch == nil` means the
        /// repo's default branch.
        case workflow(file: String, branch: String?)
        /// A specific, frozen workflow run.
        case run(id: Int)
    }

    public init(url: String, owner: String, repo: String, target: Target) {
        self.url = url; self.owner = owner; self.repo = repo; self.target = target
    }

    public var fullName: String { "\(owner)/\(repo)" }

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
        }
    }

    /// Stable identifier used for SwiftUI lists + dedupe checks.
    public var id: String {
        switch target {
        case .workflow(let file, let branch):
            return "\(owner)/\(repo)/wf/\(file)/\(branch ?? "*")"
        case .run(let id):
            return "\(owner)/\(repo)/run/\(id)"
        }
    }

    /// Parse any github.com URL the user might paste — workflow file
    /// URL, workflow run URL, optionally with a `?branch=…` query.
    /// Rejects non-github hosts so we never hit the API with bad data.
    public static func parse(_ raw: String) -> PipelineSpec? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

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
}

/// Aggregated job counts + overall state for a single tracked pipeline.
public struct PipelineStatus: Identifiable, Equatable {
    public var id: String { spec.id }
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
}
