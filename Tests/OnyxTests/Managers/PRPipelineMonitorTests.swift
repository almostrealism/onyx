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
