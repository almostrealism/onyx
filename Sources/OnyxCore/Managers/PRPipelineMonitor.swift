//
// PRPipelineMonitor.swift
//
// Responsibility: For every open PR the app knows about, the latest CI on
//                 its head branch — fetched without the user tracking
//                 anything, and published for the monitor and the menu bar.
// Scope: Shared singleton (PRPipelineMonitor.shared). Fed the PR list by
//        AppState; it does not reach into the PR managers itself.
// Threading: Poll on main; fetches on URLSession; results land on main.
//
// The tracked-pipeline flow (WorkflowMonitor) answers "how is workflow X
// on branch Y", and the user has to say which X and Y. This answers the
// question people were using it for: "is the CI on my PR green" — which
// needs no input at all, because the PR names its own branch. Before this
// existed the user added a tracked pipeline for every PR they opened, and
// removed it after the merge, by hand.
//
// Cost: one request per PR per tick (the runs on its branch), plus one
// more per RED run to learn which jobs failed. Twenty open PRs is twenty
// requests a minute — well inside GitHub's 5000/hour.
//

import Foundation
import Combine

public final class PRPipelineMonitor: ObservableObject {

    public static let shared = PRPipelineMonitor()

    /// Latest runs by `PullRequest.id`, each PR's list ordered by
    /// workflow name. A PR with no CI on its branch has no entry.
    @Published public private(set) var runs: [String: [PRPipelineRun]] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: String?

    /// Same cadence as the tracked pipelines: a run changes state on the
    /// scale of a minute, and slower than that feels stale.
    public static let pollInterval: TimeInterval = 60

    private lazy var poll = PollLoop(interval: Self.pollInterval) { [weak self] in self?.tick() }
    private var inFlight = false
    private var prs: [PullRequest] = []
    private var subscription: AnyCancellable?
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    /// Follow a PR list. A change in WHICH PRs are open (or which branch
    /// one points at) refetches at once rather than waiting out the
    /// tick — a PR you just opened should show its CI when the PR does.
    public func start(following prPublisher: AnyPublisher<[PullRequest], Never>) {
        subscription = prPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prs in
                guard let self else { return }
                let changed = Set(prs.map(Self.identity)) != Set(self.prs.map(Self.identity))
                self.prs = prs
                if changed { self.poll.refresh() }
            }
        poll.start()
    }

    public func stop() {
        poll.stop()
        subscription = nil
    }

    public func refresh() { poll.refresh() }

    private static func identity(_ pr: PullRequest) -> String {
        "\(pr.id)@\(pr.headBranch ?? "")"
    }

    /// The runs for one PR that the user has opted into, in display
    /// order. Filtered on the way out, not at fetch time, so a change in
    /// settings shows at once rather than at the next poll.
    public func runs(for pr: PullRequest) -> [PRPipelineRun] {
        (runs[pr.id] ?? []).filter(WorkflowFilterStore.shared.keeps)
    }

    /// Every opted-in run, for the menu bar.
    public var allRuns: [PRPipelineRun] {
        runs.values.flatMap { $0 }.filter(WorkflowFilterStore.shared.keeps)
    }

    // MARK: - Poll cycle

    private func tick() {
        guard !inFlight else { return }
        let ghToken = GitHubConfigStore.shared.token
        let glToken = GitLabConfigStore.shared.token
        let targets = prs.filter { pr in
            guard let branch = pr.headBranch, !branch.isEmpty else { return false }
            switch pr.provider {
            case .github: return !ghToken.isEmpty
            case .gitlab: return !glToken.isEmpty
            }
        }
        guard !targets.isEmpty else {
            runs = [:]
            lastError = nil
            return
        }
        inFlight = true
        isLoading = true

        let group = DispatchGroup()
        var collected: [String: [PRPipelineRun]] = [:]
        var firstError: String?
        let lock = NSLock()

        for pr in targets {
            group.enter()
            let done: (Result<[PRPipelineRun], Error>) -> Void = { result in
                lock.lock()
                switch result {
                case .success(let list): if !list.isEmpty { collected[pr.id] = list }
                case .failure(let e): if firstError == nil { firstError = e.localizedDescription }
                }
                lock.unlock()
                group.leave()
            }
            switch pr.provider {
            case .github: fetchGitHub(pr: pr, token: ghToken, completion: done)
            case .gitlab: fetchGitLab(pr: pr, token: glToken, completion: done)
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.inFlight = false
            self.isLoading = false
            self.lastError = firstError
            // A PR that has left the list takes its runs with it; one
            // whose fetch failed this tick keeps what it had.
            let live = Set(targets.map(\.id))
            var next = self.runs.filter { live.contains($0.key) }
            for (key, value) in collected { next[key] = value }
            self.runs = next
            // Every workflow found, opted into or not — that is how the
            // settings list learns what there is to choose from.
            WorkflowFilterStore.shared.noteSeen(collected.values.flatMap { $0 }.map(\.name))
        }
    }

    // MARK: - GitHub

    /// The runs on the head branch, newest first; the first of each
    /// workflow is its latest. A run that is red, running or queued gets
    /// a second request for its jobs — the failed ones by name, and
    /// whichever one the run is actually on right now.
    private func fetchGitHub(pr: PullRequest, token: String,
                             completion: @escaping (Result<[PRPipelineRun], Error>) -> Void) {
        let parts = pr.repoFullName.split(separator: "/").map(String.init)
        guard parts.count == 2, let branch = pr.headBranch else { completion(.success([])); return }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.github.com"
        comps.path = "/repos/\(parts[0])/\(parts[1])/actions/runs"
        comps.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "per_page", value: "30"),
        ]
        guard let url = comps.url else { completion(.success([])); return }
        var req = URLRequest(url: url)
        applyGitHubAuth(&req, token: token)

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                completion(.failure(Self.httpError("GitHub", http.statusCode))); return
            }
            guard let data,
                  let decoded = try? JSONDecoder().decode(RunsResponse.self, from: data) else {
                completion(.success([])); return
            }
            let latest = Self.latestPerWorkflow(decoded.workflow_runs ?? [])
            let group = DispatchGroup()
            var out: [PRPipelineRun] = []
            let lock = NSLock()
            for run in latest {
                let overall = PipelineOverallStatus.fromGitHub(status: run.status,
                                                               conclusion: run.conclusion)
                let base = PRPipelineRun(
                    id: "\(pr.id)/\(run.path ?? "\(run.id)")",
                    prID: pr.id,
                    name: run.name ?? ((run.path ?? "workflow") as NSString)
                        .lastPathComponent.replacingOccurrences(of: ".yml", with: ""),
                    overall: overall,
                    runNumber: run.run_number,
                    attempt: run.run_attempt,
                    url: run.html_url,
                    updatedAt: run.updated_at.flatMap(Self.date))
                // The jobs request only pays off for a run someone will
                // see, and only when there is something in it to say: what
                // failed, or what it is working on. A finished green run
                // needs neither, and a workflow that isn't opted in gets
                // the cheap version — still enough to offer it in settings.
                guard Self.wantsJobs(overall),
                      WorkflowFilterStore.shared.isIncluded(base.name) else {
                    lock.lock(); out.append(base); lock.unlock()
                    continue
                }
                group.enter()
                self.fetchJobs(owner: parts[0], repo: parts[1], runID: run.id,
                               token: token) { summary in
                    lock.lock()
                    out.append(PRPipelineRun(
                        id: base.id, prID: base.prID, name: base.name, overall: base.overall,
                        runNumber: base.runNumber, attempt: base.attempt, url: base.url,
                        updatedAt: base.updatedAt, failedJobs: summary.failed,
                        activeJob: summary.active))
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                completion(.success(out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }))
            }
        }.resume()
    }

    /// The API orders runs newest first, so the first seen of each
    /// workflow path IS its latest. Internal for the test.
    static func latestPerWorkflow(_ runs: [RunsResponse.Run]) -> [RunsResponse.Run] {
        var seen: Set<String> = []
        return runs.filter { run in
            let key = run.path ?? "run-\(run.id)"
            return seen.insert(key).inserted
        }
    }

    /// Whether a run's jobs are worth a request: something failed, or it
    /// hasn't finished. Internal for the test.
    static func wantsJobs(_ overall: PipelineOverallStatus) -> Bool {
        switch overall {
        case .failure, .mixed, .running, .queued: return true
        case .success, .skipped, .unknown:        return false
        }
    }

    /// What one run's job list is worth saying.
    struct JobSummary {
        let failed: [String]
        let active: PRPipelineRun.ActiveJob?
    }

    private func fetchJobs(owner: String, repo: String, runID: Int, token: String,
                           completion: @escaping (JobSummary) -> Void) {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.github.com"
        comps.path = "/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs"
        comps.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = comps.url else {
            completion(JobSummary(failed: [], active: nil)); return
        }
        var req = URLRequest(url: url)
        applyGitHubAuth(&req, token: token)
        session.dataTask(with: req) { data, _, _ in
            guard let data,
                  let decoded = try? JSONDecoder().decode(JobsResponse.self, from: data) else {
                completion(JobSummary(failed: [], active: nil)); return
            }
            let jobs = decoded.jobs ?? []
            completion(JobSummary(failed: Self.failedJobNames(jobs),
                                  active: Self.activeJob(jobs)))
        }.resume()
    }

    /// The job the run is on right now.
    ///
    /// Running jobs win, newest start first: a run with four jobs in
    /// flight is most usefully described by the one it just picked up.
    /// With nothing running, a run that isn't over is waiting, so the
    /// most recently CREATED queued job is the answer — GitHub stamps a
    /// job's `created_at` even before it starts, which is the only
    /// ordering available for something that has no start time. Where
    /// even that is missing, document order is creation order, so the
    /// last one listed is the newest.
    ///
    /// Internal for the test.
    static func activeJob(_ jobs: [JobsResponse.Job]) -> PRPipelineRun.ActiveJob? {
        func newest(_ candidates: [(name: String, at: Date?)]) -> (name: String, at: Date?)? {
            guard !candidates.isEmpty else { return nil }
            let stamped = candidates.filter { $0.at != nil }
            // Fall back to the LAST listed rather than the first: the API
            // lists jobs in the order they were created.
            guard !stamped.isEmpty else { return candidates.last }
            return stamped.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        }

        let running = jobs
            .filter { $0.status == "in_progress" }
            .compactMap { job -> (name: String, at: Date?)? in
                guard let name = job.name else { return nil }
                return (name, (job.started_at ?? job.created_at).flatMap(date))
            }
        if let job = newest(running) {
            return PRPipelineRun.ActiveJob(name: job.name, state: .running, since: job.at)
        }

        let waiting = jobs
            .filter { Self.queuedStatuses.contains($0.status ?? "") }
            .compactMap { job -> (name: String, at: Date?)? in
                guard let name = job.name else { return nil }
                return (name, job.created_at.flatMap(date))
            }
        if let job = newest(waiting) {
            return PRPipelineRun.ActiveJob(name: job.name, state: .queued, since: job.at)
        }
        return nil
    }

    /// GitHub's words for "accepted, not started". `waiting` is a job
    /// held for a deployment approval; `requested`/`pending` appear while
    /// a runner is being allocated.
    static let queuedStatuses: Set<String> = ["queued", "waiting", "requested", "pending"]

    /// Internal for the test.
    static func failedJobNames(_ jobs: [JobsResponse.Job]) -> [String] {
        jobs.filter { ["failure", "timed_out", "startup_failure"].contains($0.conclusion ?? "") }
            .compactMap(\.name)
    }

    private func applyGitHubAuth(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    // MARK: - GitLab

    /// The MR's own pipelines endpoint, newest first. A pipeline that is
    /// red, running or waiting gets a second request for its jobs — the
    /// failed ones by name, and whichever one it is on right now.
    private func fetchGitLab(pr: PullRequest, token: String,
                             completion: @escaping (Result<[PRPipelineRun], Error>) -> Void) {
        let project = pr.repoFullName.addingPercentEncoding(withAllowedCharacters: GitLabPath.allowed)
            ?? pr.repoFullName
        guard var comps = URLComponents(
            string: "https://gitlab.com/api/v4/projects/\(project)/merge_requests/\(pr.number)/pipelines")
        else { completion(.success([])); return }
        comps.queryItems = [URLQueryItem(name: "per_page", value: "1")]
        guard let url = comps.url else { completion(.success([])); return }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                completion(.failure(Self.httpError("GitLab", http.statusCode))); return
            }
            guard let data,
                  let pipelines = try? JSONDecoder().decode([GitLabPipeline].self, from: data),
                  let latest = pipelines.first else {
                completion(.success([])); return
            }
            let overall = PipelineOverallStatus.fromGitLab(latest.status)
            let base = PRPipelineRun(
                id: "\(pr.id)/pipeline",
                prID: pr.id,
                name: "Pipeline",
                overall: overall,
                runNumber: latest.id,
                attempt: nil,
                url: latest.web_url,
                updatedAt: latest.updated_at.flatMap(Self.date))
            guard Self.wantsJobs(overall),
                  WorkflowFilterStore.shared.isIncluded(base.name) else {
                completion(.success([base])); return
            }
            // The whole job list, not `scope=failed`: the same request has
            // to answer "what failed" and "what is it on", and a second
            // scoped call per pipeline per minute buys nothing.
            guard let jobsURL = URL(string:
                "https://gitlab.com/api/v4/projects/\(project)/pipelines/\(latest.id)/jobs?per_page=100")
            else { completion(.success([base])); return }
            var jobsReq = URLRequest(url: jobsURL)
            jobsReq.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
            self.session.dataTask(with: jobsReq) { data, _, _ in
                let jobs = data.flatMap { try? JSONDecoder().decode([GitLabJob].self, from: $0) } ?? []
                completion(.success([PRPipelineRun(
                    id: base.id, prID: base.prID, name: base.name, overall: base.overall,
                    runNumber: base.runNumber, attempt: nil, url: base.url,
                    updatedAt: base.updatedAt,
                    failedJobs: Self.failedGitLabJobNames(jobs),
                    activeJob: Self.activeGitLabJob(jobs))]))
            }.resume()
        }.resume()
    }

    /// GitLab says `failed` on the job itself. `allow_failure` jobs also
    /// say `failed` and are deliberately included: a red job is worth
    /// naming whether or not the pipeline chose to survive it.
    static func failedGitLabJobNames(_ jobs: [GitLabJob]) -> [String] {
        jobs.filter { $0.status == "failed" }.compactMap(\.name)
    }

    /// The GitLab counterpart of `activeJob`, with GitLab's vocabulary:
    /// `running`, then the several words it uses for "not started yet".
    /// A queued job has `created_at` but no `started_at`, same as
    /// GitHub — so the ordering rule is identical.
    static func activeGitLabJob(_ jobs: [GitLabJob]) -> PRPipelineRun.ActiveJob? {
        func newest(_ candidates: [(name: String, at: Date?)]) -> (name: String, at: Date?)? {
            guard !candidates.isEmpty else { return nil }
            let stamped = candidates.filter { $0.at != nil }
            guard !stamped.isEmpty else { return candidates.last }
            return stamped.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        }

        let running = jobs.filter { $0.status == "running" }
            .compactMap { job -> (name: String, at: Date?)? in
                guard let name = job.name else { return nil }
                return (name, (job.started_at ?? job.created_at).flatMap(date))
            }
        if let job = newest(running) {
            return PRPipelineRun.ActiveJob(name: job.name, state: .running, since: job.at)
        }

        let waiting = jobs.filter { gitlabQueuedStatuses.contains($0.status ?? "") }
            .compactMap { job -> (name: String, at: Date?)? in
                guard let name = job.name else { return nil }
                return (name, job.created_at.flatMap(date))
            }
        if let job = newest(waiting) {
            return PRPipelineRun.ActiveJob(name: job.name, state: .queued, since: job.at)
        }
        return nil
    }

    /// GitLab's words for "not started yet". `manual` is excluded on
    /// purpose: a manual job is waiting for a PERSON, not a runner, and
    /// reporting it as queued would make a pipeline that has stopped and
    /// is waiting on you look like one that is getting on with it.
    static let gitlabQueuedStatuses: Set<String> = [
        "created", "pending", "preparing", "waiting_for_resource", "scheduled",
    ]

    // MARK: - Helpers

    private static func httpError(_ forge: String, _ code: Int) -> Error {
        NSError(domain: "PRPipelineMonitor", code: code,
                userInfo: [NSLocalizedDescriptionKey: "\(forge) HTTP \(code)"])
    }

    /// GitHub sends `2024-05-01T12:00:00Z`; GitLab adds milliseconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: - Response shapes

    /// Internal so the decoding can be tested against a real payload:
    /// a mistyped key compiles and yields nil forever.
    struct RunsResponse: Decodable {
        let workflow_runs: [Run]?
        struct Run: Decodable {
            let id: Int
            let name: String?
            let path: String?         // ".github/workflows/ci.yml"
            let status: String?       // queued / in_progress / completed
            let conclusion: String?   // success / failure / … once completed
            let run_number: Int?
            let run_attempt: Int?
            let html_url: String?
            let updated_at: String?
        }
    }

    struct JobsResponse: Decodable {
        let jobs: [Job]?
        struct Job: Decodable {
            let name: String?
            /// queued / in_progress / completed / waiting / requested / pending
            let status: String?
            let conclusion: String?
            /// When it began executing. Null while queued.
            let started_at: String?
            /// When it was created — the only stamp a queued job has.
            let created_at: String?
        }
    }

    private struct GitLabPipeline: Decodable {
        let id: Int
        let status: String?
        let web_url: String?
        let updated_at: String?
    }

    /// Internal so the decoding can be tested against a real payload.
    struct GitLabJob: Decodable {
        let name: String?
        /// created / pending / running / failed / success / canceled /
        /// manual / waiting_for_resource / preparing / scheduled
        let status: String?
        let started_at: String?
        let created_at: String?
    }
}
