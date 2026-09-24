//
// PRPipelineModels.swift
//
// Responsibility: The latest CI on an open PR — what the monitor shows
//                 under each PR without anyone adding a tracked pipeline.
// Scope: Model. Pure data plus the status mapping, which is where a
//        forge's vocabulary becomes ours and is the part worth testing.
//
// Why this exists: tracked pipelines (PipelineSpec) are the right tool
// for a workflow you care about on its own — a nightly, a release. But
// the pipeline most people actually watch is "the CI on the PR I'm
// waiting to merge", and that one is fully determined by the PR. Making
// the user add it by hand, PR after PR, is busywork the app can do.
//

import Foundation

/// The most recent run of one workflow (GitHub) or the latest pipeline
/// (GitLab) on an open PR's head branch.
public struct PRPipelineRun: Identifiable, Equatable {
    /// Unique per (PR, workflow). Stable across polls so rows don't churn.
    public let id: String
    /// The `PullRequest.id` this belongs to.
    public let prID: String
    /// The workflow's display name — "CI", "Build" — or "Pipeline" on
    /// GitLab, where a project has one.
    public let name: String
    public let overall: PipelineOverallStatus
    public let runNumber: Int?
    /// GitHub's `run_attempt`; nil on GitLab.
    public let attempt: Int?
    /// The run's own page.
    public let url: String?
    public let updatedAt: Date?
    /// Names of the jobs that failed, when the run did — the thing you
    /// would otherwise open the run to find out. Empty while green or
    /// still running.
    public let failedJobs: [String]
    /// What the run is doing RIGHT NOW: the job that started most
    /// recently, or — when nothing is running and the run isn't over —
    /// the job most recently queued. Nil for a finished run.
    ///
    /// "Still running" on its own says nothing: a five-minute unit-test
    /// job and a forty-minute deploy look identical from outside. The
    /// job's name is what tells you which.
    public let activeJob: ActiveJob?

    public init(id: String, prID: String, name: String, overall: PipelineOverallStatus,
                runNumber: Int?, attempt: Int?, url: String?, updatedAt: Date?,
                failedJobs: [String] = [], activeJob: ActiveJob? = nil) {
        self.id = id; self.prID = prID; self.name = name; self.overall = overall
        self.runNumber = runNumber; self.attempt = attempt; self.url = url
        self.updatedAt = updatedAt; self.failedJobs = failedJobs
        self.activeJob = activeJob
    }

    /// One job inside a run, and whether it has started.
    public struct ActiveJob: Equatable {
        public enum State: String, Equatable {
            /// Executing now.
            case running
            /// Accepted and waiting for a runner, or waiting on a
            /// dependency or an approval.
            case queued
        }

        public let name: String
        public let state: State
        /// When it started (running) or was created (queued). Nil where
        /// the forge didn't say — the name is still worth showing.
        public let since: Date?

        public init(name: String, state: State, since: Date?) {
            self.name = name; self.state = state; self.since = since
        }
    }

    /// True when this is a re-run — the only case worth showing.
    public var isRetry: Bool { (attempt ?? 1) > 1 }

    /// Something a person should look at: it went red, or it's waiting
    /// on someone (GitHub's `action_required`).
    public var needsAttention: Bool {
        overall == .failure || overall == .mixed
    }
}

extension PipelineOverallStatus {

    /// GitHub's two-field vocabulary — `status` while a run is alive,
    /// `conclusion` once it has finished — folded into one.
    ///
    /// `action_required` is a run that will never start by itself (a
    /// fork PR awaiting approval to run, a deployment waiting for a
    /// reviewer). It is reported as queued, which is what it looks like,
    /// rather than as a failure, which it isn't yet.
    public static func fromGitHub(status: String?, conclusion: String?) -> PipelineOverallStatus {
        switch status {
        case "in_progress":                                return .running
        case "queued", "waiting", "requested", "pending":  return .queued
        case "completed", nil:                             break
        default:                                           return .unknown
        }
        switch conclusion {
        case "success":                                       return .success
        case "failure", "timed_out", "startup_failure":       return .failure
        case "cancelled", "skipped", "neutral", "stale":      return .skipped
        case "action_required":                               return .queued
        case nil:                                             return status == nil ? .unknown : .running
        default:                                              return .unknown
        }
    }

    /// GitLab's single pipeline-level `status` string.
    public static func fromGitLab(_ status: String?) -> PipelineOverallStatus {
        switch status {
        case "success":                         return .success
        case "failed":                          return .failure
        case "running":                         return .running
        case "created", "pending", "preparing",
             "waiting_for_resource", "scheduled": return .queued
        case "skipped", "manual", "canceled":   return .skipped
        default:                                return .unknown
        }
    }
}
