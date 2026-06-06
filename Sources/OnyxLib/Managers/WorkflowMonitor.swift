//
// WorkflowMonitor.swift
//
// Responsibility: Polls GitHub Actions for every pipeline the user has
//                 added (PipelineSpec) and publishes a flat
//                 [PipelineStatus] for the monitor overlay.
// Scope: Shared singleton (WorkflowMonitor.shared).
// Threading: Timer fires on main; per-pipeline fetches dispatch to
//            URLSession; results merge back on main.
//

import Foundation
import Combine

public final class WorkflowMonitor: ObservableObject {

    public static let shared = WorkflowMonitor()

    @Published public private(set) var pipelines: [PipelineStatus] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isLoading: Bool = false

    /// 60s — pipelines change state on the scale of seconds-to-minutes
    /// during a run, so anything slower feels stale. Each pipeline
    /// costs ~2 REST calls per poll; even 30 pipelines stays well
    /// under the 5000/hour limit.
    public static let pollInterval: TimeInterval = 60

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
        timer?.invalidate(); timer = nil
    }

    public func refresh() {
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    // MARK: - Poll cycle

    private func tick() {
        guard !inFlight else { return }
        let config = GitHubConfigStore.shared
        let token = config.token
        let specs = config.parsedPipelines
        if token.isEmpty || specs.isEmpty {
            pipelines = []
            lastError = nil
            return
        }
        inFlight = true
        isLoading = true

        let group = DispatchGroup()
        var collected: [PipelineStatus] = []
        var firstError: String?
        let lock = NSLock()

        for spec in specs {
            group.enter()
            fetch(spec: spec, token: token) { result in
                lock.lock()
                switch result {
                case .success(let s): collected.append(s)
                case .failure(let e):
                    if firstError == nil { firstError = e.localizedDescription }
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
            // Preserve user-facing order (the order in pipelineURLs).
            let byId = Dictionary(uniqueKeysWithValues: collected.map { ($0.id, $0) })
            self.pipelines = specs.compactMap { byId[$0.id] }
        }
    }

    // MARK: - REST fetch

    private func fetch(spec: PipelineSpec,
                       token: String,
                       completion: @escaping (Result<PipelineStatus, Error>) -> Void) {
        switch spec.target {
        case .run(let id):
            fetchJobs(spec: spec, runID: id, token: token,
                      runNumber: nil, runURL: nil,
                      headBranch: nil, title: nil,
                      completion: completion)
        case .workflow(let file, let branch):
            // 1. Find the latest run on the (file, branch) combo.
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.github.com"
            components.path = "/repos/\(spec.owner)/\(spec.repo)/actions/workflows/\(file)/runs"
            var q = [URLQueryItem(name: "per_page", value: "1")]
            if let branch = branch {
                q.append(URLQueryItem(name: "branch", value: branch))
            }
            components.queryItems = q
            guard let url = components.url else {
                completion(.failure(NSError(domain: "WorkflowMonitor", code: 1)))
                return
            }
            var req = URLRequest(url: url)
            applyAuth(&req, token: token)
            session.dataTask(with: req) { [weak self] data, _, error in
                if let e = error { completion(.failure(e)); return }
                guard let data = data,
                      let runs = try? JSONDecoder().decode(WorkflowRunsResponse.self, from: data),
                      let latest = runs.workflow_runs?.first else {
                    completion(.failure(NSError(
                        domain: "WorkflowMonitor", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No runs found for workflow \(file) on \(branch ?? "default branch")"])))
                    return
                }
                self?.fetchJobs(spec: spec, runID: latest.id, token: token,
                                runNumber: latest.run_number,
                                runURL: latest.html_url,
                                headBranch: latest.head_branch,
                                title: latest.display_title ?? latest.name,
                                completion: completion)
            }.resume()
        }
    }

    private func fetchJobs(spec: PipelineSpec,
                           runID: Int,
                           token: String,
                           runNumber: Int?,
                           runURL: String?,
                           headBranch: String?,
                           title: String?,
                           completion: @escaping (Result<PipelineStatus, Error>) -> Void) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(spec.owner)/\(spec.repo)/actions/runs/\(runID)/jobs"
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            completion(.failure(NSError(domain: "WorkflowMonitor", code: 3)))
            return
        }
        var req = URLRequest(url: url)
        applyAuth(&req, token: token)

        session.dataTask(with: req) { data, _, error in
            if let e = error { completion(.failure(e)); return }
            guard let data = data,
                  let decoded = try? JSONDecoder().decode(JobsResponse.self, from: data) else {
                completion(.failure(NSError(domain: "WorkflowMonitor", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't decode jobs response"])))
                return
            }
            let jobs = decoded.jobs ?? []
            var succeeded = 0, inProgress = 0, queued = 0, skipped = 0, failed = 0
            for job in jobs {
                switch (job.status ?? "", job.conclusion) {
                case ("completed", "success"): succeeded += 1
                case ("completed", "skipped"): skipped += 1
                case ("completed", "failure"), ("completed", "timed_out"),
                     ("completed", "cancelled"), ("completed", "action_required"):
                    failed += 1
                case ("completed", _):  // neutral, stale, etc.
                    succeeded += 1   // treat as a non-failure
                case ("in_progress", _): inProgress += 1
                case ("queued", _), ("waiting", _), ("pending", _): queued += 1
                default: queued += 1
                }
            }
            let overall: PipelineOverallStatus
            if failed > 0 && succeeded > 0 { overall = .mixed }
            else if failed > 0 { overall = .failure }
            else if inProgress > 0 { overall = .running }
            else if queued > 0 && succeeded == 0 { overall = .queued }
            else if jobs.isEmpty { overall = .unknown }
            else if skipped > 0 && succeeded == 0 && failed == 0 { overall = .skipped }
            else { overall = .success }

            let status = PipelineStatus(
                spec: spec,
                runNumber: runNumber,
                runURL: runURL,
                headBranch: headBranch,
                title: title,
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

    private func applyAuth(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    // MARK: - REST response shapes

    private struct WorkflowRunsResponse: Decodable {
        let workflow_runs: [Run]?
        struct Run: Decodable {
            let id: Int
            let run_number: Int?
            let name: String?
            let display_title: String?
            let html_url: String?
            let head_branch: String?
        }
    }
    private struct JobsResponse: Decodable {
        let jobs: [Job]?
        struct Job: Decodable {
            let status: String?       // completed / in_progress / queued / waiting / pending
            let conclusion: String?   // success / failure / cancelled / skipped / ...
        }
    }
}
