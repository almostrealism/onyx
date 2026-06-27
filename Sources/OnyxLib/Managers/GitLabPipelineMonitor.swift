//
// GitLabPipelineMonitor.swift
//
// Responsibility: Polls the GitLab REST API for the explicitly-tracked
//                 pipelines in GitLabConfigStore and publishes their
//                 status as [PipelineStatus] (provider == .gitlab) so the
//                 monitor overlay can merge them with GitHub pipelines.
// Scope: Shared singleton.
// Threading: Timer on main; fetches on URLSession; results to main.
//
// Mirrors WorkflowMonitor. Each tracked spec is a .pipeline(id) — a
// specific GitLab pipeline, like a frozen GitHub run. We fetch the
// pipeline detail (for ref + web_url) and its jobs (for the per-bucket
// counts), then roll them up with the shared status derivation.
//

import Foundation
import Combine

public final class GitLabPipelineMonitor: ObservableObject {

    public static let shared = GitLabPipelineMonitor()

    @Published public private(set) var pipelines: [PipelineStatus] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading: Bool = false

    /// 60s — pipelines change state quickly; matches WorkflowMonitor.
    public static let pollInterval: TimeInterval = 60

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
        let token = config.token
        let specs = config.parsedPipelines
        guard !token.isEmpty, !specs.isEmpty else {
            pipelines = []
            lastError = nil
            return
        }
        inFlight = true
        isLoading = true

        let group = DispatchGroup()
        var collected: [String: PipelineStatus] = [:]
        var firstError: String?
        let lock = NSLock()

        for spec in specs {
            group.enter()
            fetch(spec: spec, token: token) { result in
                lock.lock()
                switch result {
                case .success(let status): collected[status.id] = status
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
            // Preserve the user's configured order.
            self.pipelines = specs.compactMap { collected[$0.id] }
        }
    }

    // MARK: - REST fetch

    private func fetch(spec: PipelineSpec, token: String,
                       completion: @escaping (Result<PipelineStatus, Error>) -> Void) {
        guard case .pipeline(let id) = spec.target else {
            completion(.failure(GitLabError.notGitLab)); return
        }
        // 1. Pipeline detail → ref (branch) + web_url + name.
        guard let url = URL(string:
            "\(Self.apiBase)/projects/\(spec.encodedPath)/pipelines/\(id)") else {
            completion(.failure(GitLabError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        session.dataTask(with: req) { [weak self] data, response, error in
            if let e = error { completion(.failure(e)); return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                completion(.failure(GitLabError.http(http.statusCode))); return
            }
            let detail = data.flatMap { try? JSONDecoder().decode(Pipeline.self, from: $0) }
            self?.fetchJobs(spec: spec, id: id, token: token, detail: detail,
                            completion: completion)
        }.resume()
    }

    private func fetchJobs(spec: PipelineSpec, id: Int, token: String,
                           detail: Pipeline?,
                           completion: @escaping (Result<PipelineStatus, Error>) -> Void) {
        guard var components = URLComponents(string:
            "\(Self.apiBase)/projects/\(spec.encodedPath)/pipelines/\(id)/jobs") else {
            completion(.failure(GitLabError.badURL)); return
        }
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            completion(.failure(GitLabError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        session.dataTask(with: req) { data, _, error in
            if let e = error { completion(.failure(e)); return }
            let jobs = data.flatMap { try? JSONDecoder().decode([Job].self, from: $0) } ?? []

            var succeeded = 0, inProgress = 0, queued = 0, skipped = 0, failed = 0
            for job in jobs {
                switch job.status ?? "" {
                case "success":                     succeeded += 1
                case "failed", "canceled":          failed += 1
                case "running":                     inProgress += 1
                case "created", "pending", "preparing",
                     "waiting_for_resource", "scheduled":
                    queued += 1
                case "skipped", "manual":           skipped += 1
                default:                            queued += 1
                }
            }

            // Prefer job-derived overall; if there are no jobs, fall back
            // to the pipeline's own status so the row still reads sensibly.
            let overall: PipelineOverallStatus = jobs.isEmpty
                ? Self.mapPipelineStatus(detail?.status)
                : PipelineOverallStatus.derive(
                    succeeded: succeeded, inProgress: inProgress, queued: queued,
                    skipped: skipped, failed: failed, totalJobs: jobs.count)

            let status = PipelineStatus(
                spec: spec,
                runNumber: id,
                runURL: detail?.web_url ?? spec.url,
                headBranch: detail?.ref,
                title: detail?.name,
                succeeded: succeeded,
                inProgress: inProgress,
                queued: queued,
                skipped: skipped,
                failed: failed,
                overall: overall,
                lastUpdated: Date()
            )
            completion(.success(status))
        }.resume()
    }

    /// Map a GitLab pipeline-level status string to our overall enum.
    private static func mapPipelineStatus(_ s: String?) -> PipelineOverallStatus {
        switch s {
        case "success":                         return .success
        case "failed":                          return .failure
        case "running":                         return .running
        case "created", "pending", "preparing",
             "waiting_for_resource", "scheduled": return .queued
        case "skipped", "manual", "canceled":   return .skipped
        default:                                return .unknown
        }
    }

    enum GitLabError: LocalizedError {
        case notGitLab, badURL, http(Int)
        var errorDescription: String? {
            switch self {
            case .notGitLab: return "Not a GitLab pipeline"
            case .badURL: return "Bad GitLab URL"
            case .http(let code): return "GitLab HTTP \(code)"
            }
        }
    }

    // MARK: - Response shapes (private)

    private struct Pipeline: Decodable {
        let id: Int
        let status: String?
        let ref: String?
        let web_url: String?
        let name: String?
    }
    private struct Job: Decodable {
        let status: String?
    }
}
