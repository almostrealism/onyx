//
// TodayPullRequests.swift
//
// Responsibility: Open PRs in the Today page and simple mode's column — a
//                 line per PR, busy first — and the PR job pill the bottom
//                 strip shows. Shared by the Mac and the iPhone.
//
import SwiftUI
import OnyxCore

/// Open PRs in one line each: the branch, and what its CI is doing.
///
/// The detailed overlay gives a PR four lines — title, repo, then a line
/// per workflow. That is the right shape when you are reading; this is
/// the across-the-room view, so each PR gets one line and the only
/// pipeline shown is the one the PR is most recently busy with. A PR with
/// nothing running says "passed" or "failed" instead, because a branch
/// name on its own answers nothing.
public struct SimplePullRequests: View {
    @ObservedObject var today: TodayState
    @ObservedObject private var ghManager = PullRequestManager.shared
    @ObservedObject private var glManager = GitLabMergeRequestManager.shared
    @ObservedObject private var ci = PRPipelineMonitor.shared
    /// Observed so switching a workflow on in Settings lands here too —
    /// `ci.runs(for:)` reads the filter, and the filter is what changed.
    @ObservedObject private var workflowFilter = WorkflowFilterStore.shared
    let accentColor: Color

    public init(today: TodayState, accentColor: Color) {
        self._today = ObservedObject(wrappedValue: today)
        self.accentColor = accentColor
    }

    /// The charts are the point of this layout; a long PR list must not
    /// push them around. Busy ones sort first, so an overflowing list
    /// drops the quiet ones.
    public static let maxShown = 6
    private var maxShown: Int { Self.maxShown }

    /// The PRs this section lists, in its order — what the bottom strip
    /// checks so it doesn't show a job the panel already shows.
    public static func shown(today: TodayState) -> [PullRequest] {
        Array(today.orderedPullRequests().prefix(maxShown))
    }

    public var body: some View {
        let prs = today.orderedPullRequests()
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("OPEN PRs")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(accentColor)
                    .tracking(2)

                ForEach(Array(prs.prefix(maxShown))) { pr in
                    SimplePRLine(pr: pr, runs: ci.runs(for: pr), accentColor: accentColor)
                }

                if prs.count > maxShown {
                    Text("+\(prs.count - maxShown) more")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.35))
                }
            }
        }
    }
}

/// One PR: branch on the left, what it's doing on the right.
public struct SimplePRLine: View {
    @Environment(\.openURL) private var openURL
    let pr: PullRequest
    let runs: [PRPipelineRun]
    let accentColor: Color

    public init(pr: PullRequest, runs: [PRPipelineRun], accentColor: Color) {
        self.pr = pr
        self.runs = runs
        self.accentColor = accentColor
    }

    public var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.branchLabel(pr))
                    .monitorFont(size: 12)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if let job = PRPipelineRun.mostRecentlyActive(runs)?.activeJob {
                    // The job alone. The workflow's name cost the branch
                    // its characters and told you little: job names are
                    // rarely shared between workflows, and the settled
                    // verdict below never named one either. Hover for it.
                    Text(job.name)
                        .monitorFont(size: 12)
                        .foregroundColor(job.state == .running
                                         ? Color.onyxBlue.opacity(0.9)
                                         : Color.onyxAmber.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(2)
                } else if let settled = PRPipelineRun.settledSummary(runs) {
                    Text(settled.text)
                        .monitorFont(size: 11)
                        .foregroundColor(settled.failing
                                         ? Color.onyxRed.opacity(0.85)
                                         : Color.onyxGreen.opacity(0.7))
                        .layoutPriority(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    /// The title, and the workflow the shown job belongs to.
    private var tooltip: String {
        guard let run = PRPipelineRun.mostRecentlyActive(runs),
              let job = run.activeJob else { return pr.title }
        return "\(pr.title)\n\(run.name) · \(job.name)"
    }

    public static func branchLabel(_ pr: PullRequest) -> String {
        PRJobStripSource.branchLabel(pr)
    }

    private func open() {
        guard let url = URL(string: pr.url) else { return }
        openURL(url)
    }
}

/// A PR's job in flight: the branch, small, then the job in the side
/// panel's colors — blue running, amber queued. Click opens the PR.
public struct PRJobPill: View {
    @Environment(\.openURL) private var openURL
    let activity: PRJobActivity

    public init(activity: PRJobActivity) {
        self.activity = activity
    }

    public var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                // Capped by characters, not a frame: a width cap pads a
                // short branch out to the full width.
                Text(BranchLabel.compact(activity.branch))
                    .monitorFont(size: 9)
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                Text(activity.job)
                    .monitorFont(size: 11)
                    .foregroundColor(activity.state == .running
                                     ? Color.onyxBlue.opacity(0.9)
                                     : Color.onyxAmber.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.04))
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(activity.prTitle)\n\(activity.branch)\n\(activity.workflow) · \(activity.job) — "
              + (activity.state == .running ? "running" : "queued"))
    }

    private func open() {
        guard let url = URL(string: activity.prURL) else { return }
        openURL(url)
    }
}
