//
// PullRequestManager.swift
//
// Responsibility: Polls GitHub's GraphQL API for the user's configured
//                 watch list of repos and publishes a flat
//                 [PullRequest] list for the monitor overlay.
// Scope: Shared singleton (PullRequestManager.shared) — there's no
//        per-window state, and we don't want multiple windows each
//        re-fetching the same data.
// Threading: Timer fires on main; per-repo fetches dispatch to a
//            URLSession (background); results dispatched back to main
//            before mutating @Published state.
// Invariants:
//   - One in-flight poll cycle at a time per host — overlapping ticks
//     are dropped.
//   - When the user clears the token or repo list, polling stops on
//     the next tick.
//
// GraphQL query asks for `mergeStateStatus` (gated behind a preview
// header — sent below). The result drives PRMergeStatus so the section
// can show a single mergeable/blocked/conflicts indicator.
//

import Foundation
import Combine

public final class PullRequestManager: ObservableObject {

    public static let shared = PullRequestManager()

    /// Flat union of every watched repo's open PRs, sorted most-recently
    /// updated first.
    @Published public private(set) var pullRequests: [PullRequest] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading: Bool = false

    /// 120s — GitHub's GraphQL rate limit is 5000 points/hour, and each
    /// per-repo query costs ~1 point, so this is plenty conservative
    /// even with a few dozen repos.
    public static let pollInterval: TimeInterval = 120

    private var timer: Timer?
    private var inFlight = false
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    /// Start the periodic poll loop. Safe to call repeatedly; subsequent
    /// calls while already running are no-ops. Skipped under XCTest so
    /// unit tests don't hit the network.
    public func startPolling() {
        if NSClassFromString("XCTest") != nil { return }
        guard timer == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.tick() }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// External nudge — refresh now (e.g. after the user pastes a token
    /// or saves a new repo URL).
    public func refresh() {
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    // MARK: - Poll cycle

    private func tick() {
        guard !inFlight else { return }
        let config = GitHubConfigStore.shared
        guard config.isConfigured else {
            pullRequests = []
            lastError = nil
            return
        }
        let token = config.token
        let repos = config.parsedRepos
        inFlight = true
        isLoading = true

        let group = DispatchGroup()
        var collected: [PullRequest] = []
        var firstError: String?
        let collectionLock = NSLock()

        for repo in repos {
            group.enter()
            fetch(repo: repo, token: token) { result in
                collectionLock.lock()
                switch result {
                case .success(let prs): collected.append(contentsOf: prs)
                case .failure(let err):
                    if firstError == nil { firstError = err.localizedDescription }
                }
                collectionLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.inFlight = false
            self.isLoading = false
            self.lastError = firstError
            self.pullRequests = collected.sorted {
                if $0.repoFullName != $1.repoFullName { return $0.repoFullName < $1.repoFullName }
                return $0.number > $1.number
            }
        }
    }

    // MARK: - GraphQL

    private static let graphqlURL = URL(string: "https://api.github.com/graphql")!

    private static let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number
            title
            url
            mergeStateStatus
            mergeable
            reviewThreads(first: 100) {
              nodes { isResolved }
            }
          }
        }
      }
    }
    """

    private func fetch(repo: GitHubRepoSpec, token: String,
                       completion: @escaping (Result<[PullRequest], Error>) -> Void) {
        var req = URLRequest(url: Self.graphqlURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Preview header for mergeStateStatus. Even though it's been GA
        // for years now, GitHub still warns if you ask for it without
        // the header in some org configurations — cheap to include.
        req.setValue("application/vnd.github.merge-info-preview+json",
                     forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "query": Self.query,
            "variables": ["owner": repo.owner, "name": repo.name]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else {
                completion(.failure(PRError.emptyResponse)); return
            }
            do {
                let decoded = try JSONDecoder().decode(GraphQLResponse.self, from: data)
                if let errs = decoded.errors, !errs.isEmpty {
                    let msg = errs.compactMap { $0.message }.joined(separator: "; ")
                    completion(.failure(PRError.graphqlError(msg)))
                    return
                }
                let nodes = decoded.data?.repository?.pullRequests?.nodes ?? []
                let prs = nodes.map { node in
                    PullRequest(
                        repoFullName: repo.fullName,
                        number: node.number,
                        title: node.title,
                        url: node.url,
                        openCommentThreads: node.reviewThreads?.nodes?
                            .filter { $0.isResolved == false }.count ?? 0,
                        mergeStatus: PRMergeStatus.fromGraphQL(state: node.mergeStateStatus,
                                                               mergeable: node.mergeable)
                    )
                }
                completion(.success(prs))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    enum PRError: LocalizedError {
        case emptyResponse
        case graphqlError(String)
        var errorDescription: String? {
            switch self {
            case .emptyResponse: return "GitHub returned no data."
            case .graphqlError(let m): return "GitHub: \(m)"
            }
        }
    }

    // MARK: - GraphQL response shape (private)

    private struct GraphQLResponse: Decodable {
        let data: PayloadData?
        let errors: [GQLError]?
    }
    private struct GQLError: Decodable {
        let message: String?
    }
    private struct PayloadData: Decodable {
        let repository: Repo?
    }
    private struct Repo: Decodable {
        let pullRequests: PRList?
    }
    private struct PRList: Decodable {
        let nodes: [Node]?
    }
    private struct Node: Decodable {
        let number: Int
        let title: String
        let url: String
        let mergeStateStatus: String?
        let mergeable: String?
        let reviewThreads: ThreadList?
    }
    private struct ThreadList: Decodable {
        let nodes: [Thread]?
    }
    private struct Thread: Decodable {
        let isResolved: Bool
    }
}

// MARK: - mergeStateStatus → PRMergeStatus

extension PRMergeStatus {
    /// Map GitHub's GraphQL `mergeStateStatus` (with fallback to the
    /// older `mergeable` enum) into our simplified status.
    static func fromGraphQL(state: String?, mergeable: String?) -> PRMergeStatus {
        switch state {
        case "CLEAN", "HAS_HOOKS": return .ready
        case "BEHIND":             return .behind
        case "BLOCKED":            return .blocked
        case "DIRTY":              return .conflicts
        case "UNSTABLE":           return .checksFailing
        case "UNKNOWN", nil:
            // Fall back to the simpler mergeable enum.
            switch mergeable {
            case "MERGEABLE":   return .ready
            case "CONFLICTING": return .conflicts
            default:            return .unknown
            }
        default: return .unknown
        }
    }
}
