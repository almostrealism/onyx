import SwiftUI

/// Side-by-side companion to SessionNotesSection in the monitor overlay.
/// Reads from `PullRequestManager.shared` (polled in the background); the
/// section quietly omits itself when GitHub isn't configured so the
/// layout doesn't reserve empty real estate.
struct PullRequestsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var ghManager = PullRequestManager.shared
    @ObservedObject private var glManager = GitLabMergeRequestManager.shared
    @ObservedObject private var ghConfig = GitHubConfigStore.shared
    @ObservedObject private var glConfig = GitLabConfigStore.shared
    @ObservedObject private var ci = PRPipelineMonitor.shared
    /// Observed so a workflow switched on in Settings appears at once —
    /// `ci.runs(for:)` reads the filter, but the filter is what changed.
    @ObservedObject private var workflowFilter = WorkflowFilterStore.shared

    /// GitHub PRs then GitLab MRs, each already filtered/sorted by its
    /// own manager. Rows carry a provider badge so the source is clear.
    private var merged: [PullRequest] {
        // Filtered here rather than in the managers: it's a display
        // preference, so changing it takes effect immediately instead of
        // waiting for the next poll of two separate APIs.
        (ghManager.pullRequests + glManager.mergeRequests)
            .filter { appState.appearance.prDraftFilter.keeps($0) }
    }

    private var anyConfigured: Bool { ghConfig.isConfigured || glConfig.isConfigured }
    private var isLoading: Bool { ghManager.isLoading || glManager.isLoading }
    private var firstError: String? {
        // Surface an error only when there's nothing to show, so a single
        // failing provider doesn't mask the other's results.
        guard merged.isEmpty else { return nil }
        return ghManager.lastError ?? glManager.lastError
    }

    var body: some View {
        if anyConfigured {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OPEN PRs")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    if !merged.isEmpty {
                        Text("\(merged.count)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                if let error = firstError {
                    Text(error)
                        .monitorFont(size: 10)
                        .foregroundColor(.red.opacity(0.6))
                        .lineLimit(2)
                } else if merged.isEmpty {
                    Text(isLoading ? "Loading…" : "No open PRs")
                        .monitorFont(size: 11)
                        .foregroundColor(.gray.opacity(0.4))
                } else {
                    ForEach(merged) { pr in
                        PullRequestRow(pr: pr, runs: ci.runs(for: pr),
                                       accentColor: appState.accentColor)
                    }
                }
            }
        }
    }
}

/// Compact two-letter provider tag (GH / GL) for merged rows.
struct ProviderBadge: View {
    let provider: GitProvider
    var body: some View {
        Text(provider.badge)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(Color(hex: provider.badgeHex))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color(hex: provider.badgeHex).opacity(0.14))
            .cornerRadius(2)
    }
}

private struct PullRequestRow: View {
    let pr: PullRequest
    /// The latest CI on the PR's branch, fetched with no tracking needed.
    let runs: [PRPipelineRun]
    let accentColor: Color

    var body: some View {
        // The run lines are siblings of the PR button, not children of
        // it: a Button nested inside another's label is a hit-testing
        // coin toss, and each line opens a different page.
        VStack(alignment: .leading, spacing: 0) {
            prButton
            ForEach(runs) { run in
                PRPipelineRunLine(run: run, accentColor: accentColor)
            }
        }
    }

    private var prButton: some View {
        Button(action: openPR) {
            HStack(alignment: .top, spacing: 8) {
                MergeStatusDot(status: pr.mergeStatus)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .monitorFont(size: 12)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ProviderBadge(provider: pr.provider)
                        // GitLab references MRs as !123, GitHub PRs as #123.
                        Text("\(pr.repoFullName)\(pr.provider == .gitlab ? "!" : "#")\(pr.number)")
                            .monitorFont(size: 10)
                            .foregroundColor(accentColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if pr.openCommentThreads > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 9))
                                Text("\(pr.openCommentThreads)")
                                    .monitorFont(size: 9)
                            }
                            .foregroundColor(.gray.opacity(0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cornerRadius(3)
            .contentShape(Rectangle())   // whole row is the tap target
        }
        .buttonStyle(.plain)
    }

    private func openPR() {
        guard let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One workflow's latest run on a PR: `● CI #412 ↻2 · 3m ago`, and the
/// failed jobs by name when it's red — the detail you'd otherwise open
/// the run to learn. Clicking opens the run.
struct PRPipelineRunLine: View {
    let run: PRPipelineRun
    let accentColor: Color

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    PipelineStatusDot(overall: run.overall)
                    Text(run.name)
                        .monitorFont(size: 10)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(Self.detail(run))
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.5))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    // What it's actually on. "Running" says nothing —
                    // a unit-test job and a deploy look identical from
                    // out here; the job's name is the difference.
                    if let job = run.activeJob {
                        HStack(spacing: 3) {
                            Image(systemName: job.state == .running
                                  ? "play.fill" : "hourglass")
                                .font(.system(size: 7))
                            Text(job.name)
                                .monitorFont(size: 10)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(job.state == .running
                                         ? Color.onyxBlue.opacity(0.85)
                                         : Color.onyxAmber.opacity(0.8))
                        .layoutPriority(2)
                        .help(Self.jobHelp(job))
                    }
                }
                if !run.failedJobs.isEmpty {
                    Text(Self.failedLine(run))
                        .monitorFont(size: 9)
                        .foregroundColor(Color.onyxRed.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 11)
                }
            }
            .padding(.leading, 22)   // under the PR title, past its dot
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.url ?? run.name)
    }

    /// `#412 ↻2 · 3m ago` — the attempt only when it's a re-run.
    static func detail(_ run: PRPipelineRun, now: Date = Date()) -> String {
        var parts: [String] = []
        if let n = run.runNumber { parts.append("#\(n)") }
        if run.isRetry, let attempt = run.attempt { parts.append("↻\(attempt)") }
        var line = parts.joined(separator: " ")
        if let at = run.updatedAt {
            let ago = WatchStatusLine.ago(at, now: now)
            line += line.isEmpty ? ago : " · \(ago)"
        }
        return line
    }

    /// "running: test (macos) — started 2m ago", for the tooltip. The row
    /// itself has no room to say which of the two it is in words.
    static func jobHelp(_ job: PRPipelineRun.ActiveJob, now: Date = Date()) -> String {
        let verb = job.state == .running ? "running" : "queued"
        guard let since = job.since else { return "\(verb): \(job.name)" }
        let stamp = job.state == .running ? "started" : "queued"
        return "\(verb): \(job.name) — \(stamp) \(WatchStatusLine.ago(since, now: now))"
    }

    /// `failed: lint, test (macos)` — first few names, then a count.
    static func failedLine(_ run: PRPipelineRun) -> String {
        let shown = run.failedJobs.prefix(3)
        var line = "failed: " + shown.joined(separator: ", ")
        let more = run.failedJobs.count - shown.count
        if more > 0 { line += " +\(more)" }
        return line
    }

    private func open() {
        guard let url = run.url.flatMap(URL.init(string:)) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct MergeStatusDot: View {
    let status: PRMergeStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(tooltip)
    }

    private var color: Color {
        switch status {
        case .ready:         return Color.onyxGreen    // green
        case .behind:        return Color.onyxAmber    // yellow
        case .checksFailing: return Color.onyxAmber    // yellow
        case .blocked:       return Color.onyxRed    // red
        case .conflicts:     return Color.onyxRed    // red
        case .unknown:       return Color.gray.opacity(0.4)
        }
    }

    private var tooltip: String {
        switch status {
        case .ready:         return "Ready to merge"
        case .behind:        return "Behind base — needs rebase or merge"
        case .checksFailing: return "Checks failing"
        case .blocked:       return "Blocked — protections or required reviews not satisfied"
        case .conflicts:     return "Merge conflicts"
        case .unknown:       return "GitHub hasn't computed merge status yet"
        }
    }
}

/// Companion to PullRequestsSection. Lists every pipeline the user
/// has added to `GitHubConfigStore.pipelineURLs`, each row showing
/// the workflow name plus job counts for the most recent run.
/// Section header has a "+" button that opens a popover suggesting
/// pipelines derived from the latest workflow run of each open PR.
struct PipelinesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var monitor = WorkflowMonitor.shared
    @ObservedObject private var glMonitor = GitLabPipelineMonitor.shared
    @ObservedObject private var prManager = PullRequestManager.shared
    @ObservedObject private var ghConfig = GitHubConfigStore.shared
    @ObservedObject private var glConfig = GitLabConfigStore.shared
    @State private var hoveringAdd = false
    @Environment(\.monitorFontScale) private var fontScale

    private var merged: [PipelineStatus] { monitor.pipelines + glMonitor.pipelines }
    private var anyToken: Bool { !ghConfig.token.isEmpty || !glConfig.token.isEmpty }
    private var anyTracked: Bool {
        !ghConfig.parsedPipelines.isEmpty || !glConfig.parsedPipelines.isEmpty
    }
    private var isLoading: Bool { monitor.isLoading || glMonitor.isLoading }
    private var firstError: String? {
        guard merged.isEmpty else { return nil }
        return monitor.lastError ?? glMonitor.lastError
    }

    /// Route a pasted/added pipeline URL to the store for its provider —
    /// each provider's pipelines live alongside that provider's token.
    private func addPipeline(_ url: String) {
        guard let spec = PipelineSpec.parse(url) else { return }
        switch spec.provider {
        case .github:
            // Skip if an equivalent URL (same parsed id) is already tracked —
            // duplicates produce colliding ids downstream.
            guard !ghConfig.pipelineURLs.contains(where: { PipelineSpec.parse($0)?.id == spec.id }) else { return }
            ghConfig.pipelineURLs.append(url)
            WorkflowMonitor.shared.refresh()
        case .gitlab:
            guard !glConfig.pipelineURLs.contains(where: { PipelineSpec.parse($0)?.id == spec.id }) else { return }
            glConfig.pipelineURLs.append(url)
            GitLabPipelineMonitor.shared.refresh()
        }
    }

    private func removePipeline(_ status: PipelineStatus) {
        switch status.provider {
        case .github:
            ghConfig.removePipeline(status.spec)
            WorkflowMonitor.shared.refresh()
        case .gitlab:
            glConfig.removePipeline(status.spec)
            GitLabPipelineMonitor.shared.refresh()
        }
    }

    var body: some View {
        if anyToken {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("PIPELINES")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    if !merged.isEmpty {
                        Text("\(merged.count)")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                    Button(action: { appState.showPipelineAdder = true }) {
                        // A bare Image hit-tests only its glyph box (~10pt
                        // square) and .padding around it is NOT hit-testable —
                        // that is what made this button feel like it had to be
                        // hit dead-center. Give it a real square target, scale
                        // it with the UI font like everything else in the
                        // overlay, and make the whole square the hit region.
                        Image(systemName: "plus")
                            .monitorFont(size: 11, weight: .semibold, design: .default)
                            .foregroundColor(appState.accentColor)
                            .frame(width: 22 * fontScale, height: 22 * fontScale)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(hoveringAdd
                                          ? appState.accentColor.opacity(0.18)
                                          : Color.white.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringAdd = $0 }
                    .help("Add a pipeline from your open PRs, or paste a URL")
                }
                if let error = firstError {
                    Text(error)
                        .monitorFont(size: 10)
                        .foregroundColor(.red.opacity(0.6))
                        .lineLimit(2)
                } else if merged.isEmpty {
                    if !anyTracked {
                        Text("Open PRs can show their own CI — pick which workflows in Settings. Click + to track a pipeline that isn't on a PR.")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.4))
                    } else {
                        Text(isLoading ? "Loading…" : "No data")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                } else {
                    ForEach(merged) { p in
                        PipelineRow(status: p,
                                    accentColor: appState.accentColor,
                                    onRemove: { removePipeline(p) })
                    }
                }
            }
        }
    }
}

private struct PipelineRow: View {
    let status: PipelineStatus
    let accentColor: Color
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openRun) {
                HStack(alignment: .top, spacing: 8) {
                    PipelineStatusDot(overall: status.overall)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 1) {
                        // Title row: workflow name, separator, branch.
                        // Branch gets the higher layout priority so the
                        // workflow name truncates before the branch
                        // disappears. Render as inline Text rather than
                        // a chip so it's visible even when the column
                        // is very narrow — the branch is the single
                        // most useful identifier when the same workflow
                        // is being tracked on multiple branches at once.
                        HStack(spacing: 4) {
                            Text(workflowTitle)
                                .monitorFont(size: 12)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("/")
                                .monitorFont(size: 12)
                                .foregroundColor(.gray.opacity(0.4))
                                .layoutPriority(1)
                            // Always render the branch slot so it's
                            // obvious when we're missing data: "?" means
                            // the API didn't return a head_branch for
                            // the latest run, which we can then dig
                            // into. A truly empty slot would be
                            // ambiguous (view bug vs missing data).
                            Text(branchTag ?? "?")
                                .monitorFont(size: 12, weight: .medium)
                                .foregroundColor(branchTag == nil
                                                 ? .gray.opacity(0.5)
                                                 : accentColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                        }
                        HStack(spacing: 6) {
                            ProviderBadge(provider: status.provider)
                            Text(secondaryLine)
                                .monitorFont(size: 10)
                                .foregroundColor(accentColor.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            countsBadges
                                // Always reserve room for the always-visible ×.
                                .padding(.trailing, 16)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cornerRadius(3)
                .contentShape(Rectangle())   // whole row is the tap target
            }
            .buttonStyle(.plain)

            // Hover-revealed ×. This works only because the .contentShape +
            // .onHover below make the ENTIRE row rectangle the hover-trigger
            // region — so it overlaps this corner where the × renders. (Without
            // contentShape the trigger is just the left-aligned button text,
            // which never overlaps the ×, making it impossible to click.)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.85))
                    .padding(4)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop tracking this pipeline")
            .padding(.top, 4)
            .padding(.trailing, 6)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .contentShape(Rectangle())   // whole-row hit region for hover
        .onHover { hovering = $0 }
    }

    /// Workflow name without any branch suffix — the branch lives in
    /// its own slot on the title row, so we don't want it doubled up.
    /// For run-based specs we prefer the resolved workflow name from
    /// the run detail (e.g. "Build") and only fall back to "run #N"
    /// if the detail hasn't been fetched yet.
    private var workflowTitle: String {
        if let t = status.title, !t.isEmpty { return t }
        switch status.spec.target {
        case .workflow(let file, _):
            return (file as NSString).deletingPathExtension
        case .run, .pipeline:
            return status.spec.displayName
        }
    }

    /// Branch to render as a chip on the title row. Prefer the resolved
    /// `headBranch` from the run payload (always up-to-date), fall back
    /// to the branch declared in the spec URL when no run has resolved
    /// yet, and finally fall back to nil when we genuinely don't know.
    private var branchTag: String? {
        if let b = status.headBranch, !b.isEmpty { return b }
        if case .workflow(_, let branch) = status.spec.target,
           let b = branch, !b.isEmpty {
            return b
        }
        return nil
    }

    /// `owner/repo #123 ↻2` — branch lives in the chip above, so this
    /// stays compact and survives narrow columns.
    ///
    /// The attempt is shown only when it isn't the first: "attempt 1" is
    /// every pipeline nobody has retried, and saying so on all of them
    /// would hide the ones where it matters.
    private var secondaryLine: String {
        var line = status.spec.fullName
        if let n = status.runNumber { line += " #\(n)" }
        if status.isRetry, let attempt = status.attempt { line += "  ↻\(attempt)" }
        return line
    }

    /// Per-bucket counts only — suppress zeros so the row stays clean
    /// when the pipeline is just `OK / N succeeded` with no other state.
    @ViewBuilder
    private var countsBadges: some View {
        HStack(spacing: 5) {
            if status.failed > 0 {
                countBadge("xmark", status.failed, color: Color.onyxRed)
            }
            if status.inProgress > 0 {
                countBadge("arrow.triangle.2.circlepath", status.inProgress,
                           color: Color.onyxBlue)
            }
            if status.queued > 0 {
                countBadge("hourglass", status.queued, color: Color.onyxAmber)
            }
            if status.succeeded > 0 {
                countBadge("checkmark", status.succeeded, color: Color.onyxGreen)
            }
            if status.skipped > 0 {
                countBadge("forward", status.skipped, color: .gray.opacity(0.5))
            }
        }
    }

    private func countBadge(_ symbol: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8))
            Text("\(count)")
                .monitorFont(size: 9)
        }
        .foregroundColor(color)
    }

    private func openRun() {
        // The run itself when we know it, the pipeline's page otherwise.
        guard let target = status.runURL.flatMap(URL.init(string:))
                ?? URL(string: status.spec.url) else { return }
        NSWorkspace.shared.open(target)
    }
}

struct PipelineStatusDot: View {
    let overall: PipelineOverallStatus
    var size: CGFloat = 6
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).help(tooltip)
    }
    private var color: Color {
        switch overall {
        case .running:  return Color.onyxBlue
        case .success:  return Color.onyxGreen
        case .failure:  return Color.onyxRed
        case .mixed:    return Color.onyxAmber
        case .queued:   return Color.onyxAmber
        case .skipped:  return Color.gray.opacity(0.5)
        case .unknown:  return Color.gray.opacity(0.4)
        }
    }
    private var tooltip: String {
        switch overall {
        case .running:  return "Pipeline running"
        case .success:  return "All jobs passed"
        case .failure:  return "Failed"
        case .mixed:    return "Some failures, some successes"
        case .queued:   return "Queued — hasn't started"
        case .skipped:  return "Skipped"
        case .unknown:  return "No run data yet"
        }
    }
}
