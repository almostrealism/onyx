import XCTest
@testable import OnyxLib

/// The CI on an open PR, found without tracking anything.
///
/// The user was adding a tracked pipeline for every PR they opened and
/// removing it after the merge. These lock the parts that are pure: how
/// a forge's status words become ours, which run is "the latest", and
/// what the line under a PR says.
final class PRPipelineMonitorTests: XCTestCase {

    // MARK: - Status vocabulary

    /// GitHub says two things about a run — `status` while it lives,
    /// `conclusion` once it's done. Both must be read.
    func testGitHubStatusAndConclusionFoldIntoOne() {
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "in_progress", conclusion: nil), .running)
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "queued", conclusion: nil), .queued)
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "completed", conclusion: "success"), .success)
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "completed", conclusion: "failure"), .failure)
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "completed", conclusion: "timed_out"), .failure)
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "completed", conclusion: "cancelled"), .skipped)
    }

    /// A fork PR waiting for someone to approve its workflow hasn't
    /// failed; it's waiting. Calling it red would send the user to fix
    /// something that isn't broken.
    func testActionRequiredIsWaitingNotFailed() {
        XCTAssertEqual(PipelineOverallStatus.fromGitHub(status: "completed", conclusion: "action_required"),
                       .queued)
    }

    func testGitLabStatusWords() {
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("success"), .success)
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("failed"), .failure)
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("running"), .running)
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("pending"), .queued)
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("canceled"), .skipped)
        XCTAssertEqual(PipelineOverallStatus.fromGitLab("something-new"), .unknown)
    }

    // MARK: - Decoding

    /// Trimmed from a real /actions/runs?branch= response. A mistyped key
    /// compiles and yields nil forever, so the shape is locked here.
    private let runsPayload = Data("""
    {"workflow_runs":[
      {"id": 30, "name": "CI", "path": ".github/workflows/ci.yml", "status": "completed",
       "conclusion": "failure", "run_number": 412, "run_attempt": 2,
       "html_url": "https://github.com/acme/api/actions/runs/30",
       "updated_at": "2026-09-21T10:00:00Z"},
      {"id": 29, "name": "Lint", "path": ".github/workflows/lint.yml", "status": "in_progress",
       "conclusion": null, "run_number": 88, "run_attempt": 1,
       "html_url": "https://github.com/acme/api/actions/runs/29",
       "updated_at": "2026-09-21T09:59:00Z"},
      {"id": 20, "name": "CI", "path": ".github/workflows/ci.yml", "status": "completed",
       "conclusion": "success", "run_number": 411, "run_attempt": 1,
       "html_url": "https://github.com/acme/api/actions/runs/20",
       "updated_at": "2026-09-20T10:00:00Z"}
    ]}
    """.utf8)

    func testTheRunPayloadDecodes() throws {
        let decoded = try JSONDecoder().decode(PRPipelineMonitor.RunsResponse.self, from: runsPayload)
        let first = try XCTUnwrap(decoded.workflow_runs?.first)
        XCTAssertEqual(first.path, ".github/workflows/ci.yml")
        XCTAssertEqual(first.status, "completed")
        XCTAssertEqual(first.conclusion, "failure")
        XCTAssertEqual(first.run_attempt, 2)
        XCTAssertEqual(first.updated_at, "2026-09-21T10:00:00Z")
    }

    /// The API lists newest first; the first of each workflow is its
    /// latest, and the older CI run must not appear as a second row.
    func testOnlyTheLatestRunOfEachWorkflowIsKept() throws {
        let decoded = try JSONDecoder().decode(PRPipelineMonitor.RunsResponse.self, from: runsPayload)
        let latest = PRPipelineMonitor.latestPerWorkflow(decoded.workflow_runs ?? [])
        XCTAssertEqual(latest.map(\.id), [30, 29])
    }

    func testFailedJobsAreNamed() throws {
        let payload = Data("""
        {"jobs":[{"name":"build","conclusion":"success"},
                 {"name":"test (macos)","conclusion":"failure"},
                 {"name":"lint","conclusion":"timed_out"},
                 {"name":"docs","conclusion":"skipped"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(PRPipelineMonitor.JobsResponse.self, from: payload)
        XCTAssertEqual(PRPipelineMonitor.failedJobNames(decoded.jobs ?? []), ["test (macos)", "lint"])
    }

    /// GitHub stamps whole seconds; GitLab adds milliseconds. Both are
    /// dates, and a nil here means "just now" is never shown.
    func testBothForgesDateFormatsParse() {
        XCTAssertNotNil(PRPipelineMonitor.date("2026-09-21T10:00:00Z"))
        XCTAssertNotNil(PRPipelineMonitor.date("2026-09-21T10:00:00.123Z"))
        XCTAssertNil(PRPipelineMonitor.date("yesterday"))
    }

    // MARK: - The line under a PR

    private func run(overall: PipelineOverallStatus = .success, number: Int? = 412,
                     attempt: Int? = 1, failed: [String] = [],
                     at: Date? = Date(timeIntervalSince1970: 1_000_000)) -> PRPipelineRun {
        PRPipelineRun(id: "github:acme/api#12/ci.yml", prID: "github:acme/api#12", name: "CI",
                      overall: overall, runNumber: number, attempt: attempt,
                      url: "https://github.com/acme/api/actions/runs/30", updatedAt: at,
                      failedJobs: failed)
    }

    func testTheDetailNamesTheRunAndItsAge() {
        let now = Date(timeIntervalSince1970: 1_000_000 + 180)
        XCTAssertEqual(PRPipelineRunLine.detail(run(), now: now), "#412 · 3m ago")
    }

    /// The attempt only when it's a re-run: "attempt 1" is every run.
    func testARerunShowsItsAttempt() {
        let now = Date(timeIntervalSince1970: 1_000_000 + 30)
        XCTAssertEqual(PRPipelineRunLine.detail(run(attempt: 2), now: now), "#412 ↻2 · just now")
        XCTAssertFalse(PRPipelineRunLine.detail(run(attempt: 1), now: now).contains("↻"))
    }

    func testTheFailedJobsLineNamesAFewThenCounts() {
        XCTAssertEqual(PRPipelineRunLine.failedLine(run(failed: ["lint", "test"])),
                       "failed: lint, test")
        XCTAssertEqual(PRPipelineRunLine.failedLine(run(failed: ["a", "b", "c", "d", "e"])),
                       "failed: a, b, c +2")
    }

    // MARK: - The menu bar

    private func pr(_ number: Int = 12) -> PullRequest {
        PullRequest(provider: .github, repoFullName: "acme/api", number: number,
                    title: "Fix the thing", url: "https://github.com/acme/api/pull/\(number)",
                    openCommentThreads: 0, mergeStatus: .ready, headBranch: "fix/thing",
                    author: "me", apiSaysDraft: false)
    }

    private func tracked(runURL: String?, overall: PipelineOverallStatus = .success) -> PipelineStatus {
        PipelineStatus(
            spec: PipelineSpec(url: "https://github.com/acme/api/actions/workflows/ci.yml",
                               provider: .github, path: "acme/api",
                               target: .workflow(file: "ci.yml", branch: nil)),
            runNumber: 412, runURL: runURL, headBranch: "fix/thing", title: "CI",
            succeeded: 1, inProgress: 0, queued: 0, skipped: 0, failed: 0,
            overall: overall, lastUpdated: Date())
    }

    /// A PR's CI shows up in the menu without being tracked — that is
    /// the point — and names the PR so it reads as "the CI on #12".
    func testAPRRunIsListedAndNamesItsPR() {
        let entries = MenuBarController.pipelineEntries(tracked: [], prRuns: [run()], prs: [pr()])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.title, "CI · acme/api#12")
        XCTAssertEqual(entries.first?.url, "https://github.com/acme/api/actions/runs/30")
    }

    /// The same run tracked by hand AND found on the PR is one line.
    func testARunTrackedAndFoundOnAPRAppearsOnce() {
        let entries = MenuBarController.pipelineEntries(
            tracked: [tracked(runURL: "https://github.com/acme/api/actions/runs/30")],
            prRuns: [run()], prs: [pr()])
        XCTAssertEqual(entries.count, 1)
    }

    /// Failures first, from either source.
    func testAFailingPRRunSortsAboveAGreenTrackedOne() {
        let entries = MenuBarController.pipelineEntries(
            tracked: [tracked(runURL: "https://github.com/acme/api/actions/runs/1")],
            prRuns: [run(overall: .failure)], prs: [pr()])
        XCTAssertEqual(entries.map(\.overall), [.failure, .success])
    }

    func testTheRetryIsSpelledOutInTheMenu() {
        XCTAssertTrue(MenuBarController.prRunLine(run(attempt: 3), pr: pr()).contains("attempt 3"))
        XCTAssertFalse(MenuBarController.prRunLine(run(attempt: 1), pr: pr()).contains("attempt"))
    }
}

/// Which job a run is on.
///
/// "Still running" describes a five-minute test job and a forty-minute
/// deploy identically. The job's name is the part worth having, and the
/// rule for picking one has to hold when several are in flight, when
/// none has started, and when the forge omits a timestamp.
final class ActiveJobSelectionTests: XCTestCase {

    // MARK: - GitHub

    private func decodeGitHub(_ json: String) throws -> [PRPipelineMonitor.JobsResponse.Job] {
        try JSONDecoder().decode(PRPipelineMonitor.JobsResponse.self,
                                 from: Data(json.utf8)).jobs ?? []
    }

    /// Trimmed from a real /actions/runs/<id>/jobs response. The keys are
    /// load-bearing: a typo compiles and yields nil for ever, and the
    /// symptom would be a row that never names a job.
    func testTheJobPayloadDecodes() throws {
        let jobs = try decodeGitHub("""
        {"jobs":[{"name":"build","status":"completed","conclusion":"success",
                  "started_at":"2026-09-24T10:00:00Z","created_at":"2026-09-24T09:59:00Z"}]}
        """)
        XCTAssertEqual(jobs.first?.status, "completed")
        XCTAssertEqual(jobs.first?.started_at, "2026-09-24T10:00:00Z")
        XCTAssertEqual(jobs.first?.created_at, "2026-09-24T09:59:00Z")
    }

    /// Several jobs in flight: the one that started most recently is what
    /// the run is doing now.
    func testTheNewestRunningJobWins() throws {
        let jobs = try decodeGitHub("""
        {"jobs":[
          {"name":"build","status":"completed","conclusion":"success","started_at":"2026-09-24T10:00:00Z"},
          {"name":"test (linux)","status":"in_progress","conclusion":null,"started_at":"2026-09-24T10:05:00Z"},
          {"name":"test (macos)","status":"in_progress","conclusion":null,"started_at":"2026-09-24T10:07:30Z"},
          {"name":"deploy","status":"queued","conclusion":null,"created_at":"2026-09-24T10:06:00Z"}
        ]}
        """)
        let job = try XCTUnwrap(PRPipelineMonitor.activeJob(jobs))
        XCTAssertEqual(job.name, "test (macos)")
        XCTAssertEqual(job.state, .running)
        XCTAssertEqual(job.since, PRPipelineMonitor.date("2026-09-24T10:07:30Z"))
    }

    /// Nothing running and the run isn't over: it's waiting, and the
    /// queued job with the newest `created_at` is the honest answer —
    /// the only ordering something with no start time has.
    func testWithNothingRunningTheNewestQueuedJobIsNamed() throws {
        let jobs = try decodeGitHub("""
        {"jobs":[
          {"name":"build","status":"completed","conclusion":"success","started_at":"2026-09-24T10:00:00Z"},
          {"name":"test","status":"queued","conclusion":null,"created_at":"2026-09-24T10:01:00Z"},
          {"name":"deploy","status":"queued","conclusion":null,"created_at":"2026-09-24T10:02:00Z"}
        ]}
        """)
        let job = try XCTUnwrap(PRPipelineMonitor.activeJob(jobs))
        XCTAssertEqual(job.name, "deploy")
        XCTAssertEqual(job.state, .queued)
    }

    /// A job held for a deployment approval reports `waiting`; one being
    /// assigned a runner reports `requested` or `pending`. All are "not
    /// started yet", and a run in that state must still name something.
    func testTheOtherWordsForNotStartedYetCount() throws {
        for status in ["waiting", "requested", "pending"] {
            let jobs = try decodeGitHub("""
            {"jobs":[{"name":"deploy","status":"\(status)","conclusion":null,
                      "created_at":"2026-09-24T10:02:00Z"}]}
            """)
            XCTAssertEqual(PRPipelineMonitor.activeJob(jobs)?.state, .queued, status)
        }
    }

    /// No timestamps at all — an older API response, or a forge that
    /// omits them. Document order IS creation order, so the last listed
    /// is the newest; naming it beats naming nothing.
    func testWithNoTimestampsTheLastListedJobIsUsed() throws {
        let jobs = try decodeGitHub("""
        {"jobs":[{"name":"first","status":"queued","conclusion":null},
                 {"name":"last","status":"queued","conclusion":null}]}
        """)
        let job = try XCTUnwrap(PRPipelineMonitor.activeJob(jobs))
        XCTAssertEqual(job.name, "last")
        XCTAssertNil(job.since)
    }

    /// A finished run is not doing anything, and saying it is would be
    /// worse than saying nothing.
    func testAFinishedRunNamesNoJob() throws {
        let jobs = try decodeGitHub("""
        {"jobs":[{"name":"build","status":"completed","conclusion":"success"},
                 {"name":"test","status":"completed","conclusion":"failure"}]}
        """)
        XCTAssertNil(PRPipelineMonitor.activeJob(jobs))
        XCTAssertEqual(PRPipelineMonitor.failedJobNames(jobs), ["test"])
    }

    /// One request per unfinished run, none for a settled green one.
    func testOnlyUnfinishedOrRedRunsCostAJobsRequest() {
        XCTAssertTrue(PRPipelineMonitor.wantsJobs(.running))
        XCTAssertTrue(PRPipelineMonitor.wantsJobs(.queued))
        XCTAssertTrue(PRPipelineMonitor.wantsJobs(.failure))
        XCTAssertTrue(PRPipelineMonitor.wantsJobs(.mixed))
        XCTAssertFalse(PRPipelineMonitor.wantsJobs(.success))
        XCTAssertFalse(PRPipelineMonitor.wantsJobs(.skipped))
        XCTAssertFalse(PRPipelineMonitor.wantsJobs(.unknown))
    }

    // MARK: - GitLab

    private func decodeGitLab(_ json: String) throws -> [PRPipelineMonitor.GitLabJob] {
        try JSONDecoder().decode([PRPipelineMonitor.GitLabJob].self, from: Data(json.utf8))
    }

    func testTheGitLabJobPayloadDecodesAndPicksTheNewestRunning() throws {
        let jobs = try decodeGitLab("""
        [{"name":"lint","status":"success","started_at":"2026-09-24T10:00:00.123Z",
          "created_at":"2026-09-24T09:59:00.000Z"},
         {"name":"rspec 1/3","status":"running","started_at":"2026-09-24T10:04:00.000Z",
          "created_at":"2026-09-24T10:03:00.000Z"},
         {"name":"rspec 2/3","status":"running","started_at":"2026-09-24T10:06:00.000Z",
          "created_at":"2026-09-24T10:03:00.000Z"}]
        """)
        let job = try XCTUnwrap(PRPipelineMonitor.activeGitLabJob(jobs))
        XCTAssertEqual(job.name, "rspec 2/3")
        XCTAssertEqual(job.state, .running)
    }

    func testGitLabWordsForWaiting() throws {
        for status in ["created", "pending", "preparing", "waiting_for_resource", "scheduled"] {
            let jobs = try decodeGitLab("""
            [{"name":"deploy","status":"\(status)","created_at":"2026-09-24T10:02:00.000Z"}]
            """)
            XCTAssertEqual(PRPipelineMonitor.activeGitLabJob(jobs)?.state, .queued, status)
        }
    }

    /// A `manual` job is waiting for a PERSON. Reporting it as queued
    /// would make a pipeline that has stopped and is waiting on you look
    /// like one that is getting on with it.
    func testAManualGitLabJobIsNotCalledQueued() throws {
        let jobs = try decodeGitLab("""
        [{"name":"deploy to prod","status":"manual","created_at":"2026-09-24T10:02:00.000Z"}]
        """)
        XCTAssertNil(PRPipelineMonitor.activeGitLabJob(jobs))
    }

    func testGitLabFailedJobsAreNamed() throws {
        let jobs = try decodeGitLab("""
        [{"name":"lint","status":"failed","created_at":"2026-09-24T10:00:00.000Z"},
         {"name":"rspec","status":"success","created_at":"2026-09-24T10:00:00.000Z"}]
        """)
        XCTAssertEqual(PRPipelineMonitor.failedGitLabJobNames(jobs), ["lint"])
    }

    // MARK: - The row

    func testTheTooltipSaysWhichStateAndSinceWhen() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_000_000 + 300)
        let running = PRPipelineRun.ActiveJob(name: "test (macos)", state: .running, since: started)
        XCTAssertEqual(PRPipelineRunLine.jobHelp(running, now: now),
                       "running: test (macos) — started 5m ago")

        let queued = PRPipelineRun.ActiveJob(name: "deploy", state: .queued, since: started)
        XCTAssertEqual(PRPipelineRunLine.jobHelp(queued, now: now),
                       "queued: deploy — queued 5m ago")

        let unstamped = PRPipelineRun.ActiveJob(name: "deploy", state: .queued, since: nil)
        XCTAssertEqual(PRPipelineRunLine.jobHelp(unstamped, now: now), "queued: deploy")
    }
}

/// The compact PR line in simple mode: one line per PR, showing the one
/// pipeline the PR is most recently busy with.
///
/// The detailed overlay gives a PR four lines and a row per workflow. At
/// across-the-room size there is one line, so which pipeline it names has
/// to be the right one.
final class CompactPRLineTests: XCTestCase {

    private func run(_ name: String, job: PRPipelineRun.ActiveJob?,
                     overall: PipelineOverallStatus = .running) -> PRPipelineRun {
        PRPipelineRun(id: "github:acme/api#7/\(name)", prID: "github:acme/api#7",
                      name: name, overall: overall, runNumber: 1, attempt: 1,
                      url: nil, updatedAt: nil, activeJob: job)
    }

    private func job(_ name: String, _ state: PRPipelineRun.ActiveJob.State,
                     at seconds: TimeInterval?) -> PRPipelineRun.ActiveJob {
        PRPipelineRun.ActiveJob(name: name, state: state,
                                since: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    private func pr(_ number: Int, branch: String?) -> PullRequest {
        PullRequest(provider: .github, repoFullName: "acme/api", number: number,
                    title: "Fix \(number)", url: "https://github.com/acme/api/pull/\(number)",
                    openCommentThreads: 0, mergeStatus: .ready, headBranch: branch,
                    author: "me", apiSaysDraft: false)
    }

    // MARK: - Which pipeline

    /// Two pipelines busy at once: the one whose job started most
    /// recently is what the PR is actually on.
    func testTheLatestStartedJobDecidesWhichPipelineIsShown() {
        let runs = [run("Pipeline 1", job: job("test A", .running, at: 100)),
                    run("Pipeline 2", job: job("test B", .running, at: 200))]
        let chosen = PRPipelineRun.mostRecentlyActive(runs)
        XCTAssertEqual(chosen?.name, "Pipeline 2")
        XCTAssertEqual(chosen?.activeJob?.name, "test B")
    }

    /// A queued job's stamp is a creation time and a running job's is a
    /// start time; the question asked is "what happened most recently", so
    /// they are compared directly.
    func testAQueuedJobCanOutrankAnOlderRunningOne() {
        let runs = [run("Pipeline 1", job: job("test A", .running, at: 100)),
                    run("Pipeline 2", job: job("deploy", .queued, at: 300))]
        XCTAssertEqual(PRPipelineRun.mostRecentlyActive(runs)?.activeJob?.name, "deploy")
    }

    /// Same instant, so nothing separates them by time: the running job
    /// is the one consuming it.
    func testAtTheSameInstantRunningBeatsQueued() {
        let runs = [run("Pipeline 1", job: job("waiting", .queued, at: 500)),
                    run("Pipeline 2", job: job("building", .running, at: 500))]
        XCTAssertEqual(PRPipelineRun.mostRecentlyActive(runs)?.activeJob?.name, "building")
    }

    /// No timestamps anywhere — naming a job still beats naming none, and
    /// a running one is the better guess.
    func testWithNoTimestampsARunningJobIsPreferred() {
        let runs = [run("Pipeline 1", job: job("queued thing", .queued, at: nil)),
                    run("Pipeline 2", job: job("running thing", .running, at: nil))]
        XCTAssertEqual(PRPipelineRun.mostRecentlyActive(runs)?.activeJob?.name, "running thing")
    }

    func testARunWithNoActiveJobIsNeverChosen() {
        let runs = [run("Idle", job: nil, overall: .success),
                    run("Busy", job: job("test", .running, at: 10))]
        XCTAssertEqual(PRPipelineRun.mostRecentlyActive(runs)?.name, "Busy")
        XCTAssertNil(PRPipelineRun.mostRecentlyActive([run("Idle", job: nil, overall: .success)]))
    }

    // MARK: - When nothing is running

    /// A branch name on its own answers nothing, so a quiet PR reports a
    /// verdict instead. Red outranks green: it's the one to act on.
    func testAQuietPRReportsAVerdict() {
        let green = [run("CI", job: nil, overall: .success)]
        XCTAssertEqual(PRPipelineRun.settledSummary(green)?.text, "passed")
        XCTAssertEqual(PRPipelineRun.settledSummary(green)?.failing, false)

        let red = [run("CI", job: nil, overall: .success),
                   run("Lint", job: nil, overall: .failure)]
        XCTAssertEqual(PRPipelineRun.settledSummary(red)?.text, "failed")
        XCTAssertEqual(PRPipelineRun.settledSummary(red)?.failing, true)

        XCTAssertNil(PRPipelineRun.settledSummary([]), "no runs means nothing to say")
        XCTAssertNil(PRPipelineRun.settledSummary([run("CI", job: nil, overall: .unknown)]))
    }

    // MARK: - Order and labels

    /// Busy PRs first, most recent at the top: an overflowing list drops
    /// the quiet ones, which are the ones with nothing to report.
    func testBusyPRsSortAboveQuietOnes() {
        let quiet = pr(1, branch: "chore/deps")
        let older = pr(2, branch: "fix/a")
        let newer = pr(3, branch: "fix/b")
        let byPR: [String: [PRPipelineRun]] = [
            quiet.id: [run("CI", job: nil, overall: .success)],
            older.id: [run("CI", job: job("test", .running, at: 100))],
            newer.id: [run("CI", job: job("test", .running, at: 900))],
        ]
        let ordered = SimplePullRequests.ordered([quiet, older, newer]) { byPR[$0.id] ?? [] }
        XCTAssertEqual(ordered.map(\.number), [3, 2, 1])
    }

    func testTheLineIsLabeledWithTheBranch() {
        XCTAssertEqual(SimplePRLine.branchLabel(pr(7, branch: "feature/thing")), "feature/thing")
        // GitHub omits the head branch on a PR from a deleted fork.
        XCTAssertEqual(SimplePRLine.branchLabel(pr(7, branch: nil)), "#7")
        XCTAssertEqual(SimplePRLine.branchLabel(pr(7, branch: "")), "#7")
    }
}
