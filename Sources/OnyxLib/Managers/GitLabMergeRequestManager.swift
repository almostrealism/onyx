//
// GitLabMergeRequestManager.swift
//
// Responsibility: Polls the GitLab REST API (v4, gitlab.com) for open
//                 merge requests across the user's configured projects and
//                 publishes them as [PullRequest] (provider == .gitlab) so
//                 the monitor overlay can merge them with GitHub PRs.
// Scope: Shared singleton.
// Threading: Timer on main; fetches on URLSession; results to main.
//
// Mirrors PullRequestManager's shape. The key difference for GitLab is
// that projects often have dozens of open MRs, so the "only mine" toggle
// (GitLabConfigStore.mineOnly) is applied via `scope=created_by_me`.
//

import Foundation
import Combine

public final class GitLabMergeRequestManager: ObservableObject {

    public static let shared = GitLabMergeRequestManager()

    @Published public private(set) var mergeRequests: [PullRequest] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading: Bool = false

    /// 120s — matches the GitHub PR cadence; MR state changes slowly.
    public static let pollInterval: TimeInterval = 120

    private static let apiBase = "https://gitlab.com/api/v4"

    private lazy var poll = PollLoop(interval: Self.pollInterval) { [weak self] in self?.tick() }
    private var inFlight = false
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    public func startPolling() { poll.start() }

    public func stopPolling() { poll.stop() }

    public func refresh() { poll.refresh() }

    // MARK: - Poll cycle

    private func tick() {
        guard !inFlight else { return }
        let config = GitLabConfigStore.shared
        guard config.isConfigured else {
            mergeRequests = []
            lastError = nil
            return
        }
        let token = config.token
        let projects = config.parsedProjects
        let mineOnly = config.mineOnly
        inFlight = true
        isLoading = true

        // Resolve the username for the settings readout (the MR filter
        // itself uses scope=created_by_me, so it doesn't depend on this).
        if config.username.isEmpty { resolveCurrentUser(token: token) }

        let group = DispatchGroup()
        var collected: [PullRequest] = []
        var firstError: String?
        let lock = NSLock()

        for project in projects {
            group.enter()
            fetch(project: project, token: token, mineOnly: mineOnly) { result in
                lock.lock()
                switch result {
                case .success(let mrs): collected.append(contentsOf: mrs)
                case .failure(let err):
                    if firstError == nil { firstError = err.localizedDescription }
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.inFlight = false
            self.isLoading = false
            self.lastError = firstError
            self.mergeRequests = collected.sorted {
                if $0.repoFullName != $1.repoFullName { return $0.repoFullName < $1.repoFullName }
                return $0.number > $1.number
            }
        }
    }

    /// The project an MR lives in, from `references.full`
    /// ("group/sub/project!123"). For a single-project fetch this equals
    /// the configured path; for a group fetch it's the only way to tell
    /// the projects apart, and a row saying just "fivn" would be useless.
    static func projectPath(of reference: String?, fallback: String) -> String {
        guard let reference, let bang = reference.firstIndex(of: "!") else { return fallback }
        let path = String(reference[reference.startIndex..<bang])
        return path.isEmpty ? fallback : path
    }

    // MARK: - Group vs project

    /// Which endpoint a configured path turned out to be, once GitLab has
    /// told us. Only consulted for ambiguous (multi-segment) paths.
    private enum PathKind { case project, group }
    private var resolvedKind: [String: PathKind] = [:]
    private let kindLock = NSLock()

    private func kind(for spec: GitLabProjectSpec) -> PathKind {
        if spec.isDefinitelyGroup { return .group }
        kindLock.lock(); defer { kindLock.unlock() }
        return resolvedKind[spec.path] ?? .project
    }

    private func remember(_ kind: PathKind, for spec: GitLabProjectSpec) {
        kindLock.lock(); resolvedKind[spec.path] = kind; kindLock.unlock()
    }

    // MARK: - REST fetch

    /// Fetch a configured entry's open MRs.
    ///
    /// A single-segment path is always a group. A deeper one could be
    /// either a project or a subgroup, and no amount of string
    /// inspection settles it — so we try it as a project, and on a 404
    /// try it as a group and remember which worked. That costs one wasted
    /// request, once, for a path that turns out to be a subgroup.
    private func fetch(project: GitLabProjectSpec, token: String, mineOnly: Bool,
                       completion: @escaping (Result<[PullRequest], Error>) -> Void) {
        fetch(project: project, token: token, mineOnly: mineOnly,
              as: kind(for: project), allowRetry: !project.isDefinitelyGroup,
              completion: completion)
    }

    private func fetch(project: GitLabProjectSpec, token: String, mineOnly: Bool,
                       as kind: PathKind, allowRetry: Bool,
                       completion: @escaping (Result<[PullRequest], Error>) -> Void) {
        // Group merge_requests covers the group AND its subgroups, which
        // is exactly what "watch everything under fivn" means.
        let scope = kind == .group ? "groups" : "projects"
        var components = URLComponents(
            string: "\(Self.apiBase)/\(scope)/\(project.encodedPath)/merge_requests")
        var q = [
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "order_by", value: "updated_at"),
        ]
        // `created_by_me` is server-side "mine", so it works even before
        // we've resolved the username locally.
        q.append(URLQueryItem(name: "scope", value: mineOnly ? "created_by_me" : "all"))
        components?.queryItems = q
        guard let url = components?.url else {
            completion(.failure(GitLabError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")

        session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                // 404 on an ambiguous path means we guessed wrong about
                // project-vs-group. Try the other one before reporting a
                // failure the user can't act on.
                if http.statusCode == 404, allowRetry {
                    let other: PathKind = kind == .project ? .group : .project
                    self.fetch(project: project, token: token, mineOnly: mineOnly,
                               as: other, allowRetry: false) { result in
                        if case .success = result { self.remember(other, for: project) }
                        completion(result)
                    }
                    return
                }
                completion(.failure(GitLabError.http(http.statusCode))); return
            }
            guard let data = data else {
                completion(.failure(GitLabError.emptyResponse)); return
            }
            do {
                let nodes = try JSONDecoder().decode([MR].self, from: data)
                let mrs = nodes.map { mr in
                    PullRequest(
                        provider: .gitlab,
                        repoFullName: Self.projectPath(of: mr.references?.full, fallback: project.path),
                        number: mr.iid,
                        title: mr.title,
                        url: mr.web_url,
                        openCommentThreads: (mr.blocking_discussions_resolved == false) ? 1 : 0,
                        mergeStatus: PRMergeStatus.fromGitLab(
                            detailed: mr.detailed_merge_status,
                            mergeStatus: mr.merge_status,
                            hasConflicts: mr.has_conflicts ?? false),
                        headBranch: mr.source_branch,
                        author: mr.author?.username,
                        apiSaysDraft: mr.draft ?? mr.work_in_progress ?? false
                    )
                }
                completion(.success(mrs))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// `GET /user` → username, for the settings readout.
    private func resolveCurrentUser(token: String) {
        guard let url = URL(string: "\(Self.apiBase)/user") else { return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let user = try? JSONDecoder().decode(GitLabUser.self, from: data),
                  !user.username.isEmpty else { return }
            DispatchQueue.main.async {
                if GitLabConfigStore.shared.username != user.username {
                    GitLabConfigStore.shared.username = user.username
                }
            }
        }.resume()
    }

    enum GitLabError: LocalizedError {
        case badURL, emptyResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad GitLab URL"
            case .emptyResponse: return "GitLab returned no data."
            case .http(let code): return "GitLab HTTP \(code)"
            }
        }
    }

    // MARK: - Response shapes (private)

    private struct MR: Decodable {
        let iid: Int
        /// "group/sub/project!123" — the only field that names the
        /// project an MR belongs to. Needed for group-wide fetches,
        /// where one response spans many projects.
        let references: MRReferences?
        let title: String
        let web_url: String
        let source_branch: String?
        let merge_status: String?
        let detailed_merge_status: String?
        let has_conflicts: Bool?
        /// `draft` is current; `work_in_progress` is what older GitLab
        /// returned for the same thing. Read both so a self-hosted
        /// instance a version behind still filters correctly.
        let draft: Bool?
        let work_in_progress: Bool?
        let blocking_discussions_resolved: Bool?
        let author: GitLabUser?
    }
    private struct MRReferences: Decodable {
        let full: String?
    }
    private struct GitLabUser: Decodable {
        let username: String
    }
}

// MARK: - GitLab merge status → PRMergeStatus

extension PRMergeStatus {
    /// Map GitLab's `detailed_merge_status` (15.6+) into our simplified
    /// status, falling back to the older `merge_status` enum.
    static func fromGitLab(detailed: String?, mergeStatus: String?,
                           hasConflicts: Bool) -> PRMergeStatus {
        switch detailed {
        case "mergeable":               return .ready
        case "conflict", "broken_status": return .conflicts
        case "need_rebase":             return .behind
        case "ci_still_running":        return .checksFailing
        case "draft_status", "not_approved", "blocked_status",
             "discussions_not_resolved", "ci_must_pass",
             "approvals_syncing", "jira_association_missing",
             "requested_changes", "external_status_checks":
            return .blocked
        case nil:
            // Older GitLab: fall back to the coarse merge_status.
            switch mergeStatus {
            case "can_be_merged":    return .ready
            case "cannot_be_merged": return hasConflicts ? .conflicts : .blocked
            default:                 return .unknown
            }
        default:
            return hasConflicts ? .conflicts : .unknown
        }
    }
}
