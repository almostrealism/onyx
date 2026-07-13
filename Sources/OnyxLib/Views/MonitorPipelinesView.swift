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

    /// GitHub PRs then GitLab MRs, each already filtered/sorted by its
    /// own manager. Rows carry a provider badge so the source is clear.
    private var merged: [PullRequest] {
        ghManager.pullRequests + glManager.mergeRequests
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
                        PullRequestRow(pr: pr, accentColor: appState.accentColor)
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
    let accentColor: Color

    var body: some View {
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
        }
        .buttonStyle(.plain)
    }

    private func openPR() {
        guard let url = URL(string: pr.url) else { return }
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
    @State private var showSuggestions = false

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
                    Button(action: { showSuggestions = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(appState.accentColor)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                    .help("Add a pipeline from your open PRs, or paste a URL")
                    .popover(isPresented: $showSuggestions) {
                        PipelineSuggestionsPopover(
                            prs: prManager.pullRequests,
                            existingIDs: Set(ghConfig.parsedPipelines.map(\.id)
                                             + glConfig.parsedPipelines.map(\.id)),
                            accentColor: appState.accentColor,
                            onAdd: addPipeline
                        )
                    }
                }
                if let error = firstError {
                    Text(error)
                        .monitorFont(size: 10)
                        .foregroundColor(.red.opacity(0.6))
                        .lineLimit(2)
                } else if merged.isEmpty {
                    if !anyTracked {
                        Text("Click + to add a pipeline from your open PRs, or paste a URL")
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
                                // Reserve room so the badges don't jump
                                // when the × button slides in on hover.
                                .padding(.trailing, hovering ? 16 : 0)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cornerRadius(3)
            }
            .buttonStyle(.plain)

            // Always in the hierarchy (opacity-gated, NOT a conditional) so
            // moving the pointer onto it doesn't insert a new view and flip the
            // row's .onHover off — the bug that made the × show only where it
            // couldn't be clicked. Hit-testing is gated so an invisible × never
            // eats a click meant for the row itself.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray.opacity(0.8))
                    .padding(4)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop tracking this pipeline")
            .padding(.top, 4)
            .padding(.trailing, 6)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
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

    /// `owner/repo #123` — branch lives in the chip above, so this
    /// stays compact and survives narrow columns.
    private var secondaryLine: String {
        var line = status.spec.fullName
        if let n = status.runNumber { line += " #\(n)" }
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
        if let s = status.runURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        else if let url = URL(string: status.spec.url) { NSWorkspace.shared.open(url) }
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

/// Popover content for the "+" button. Surfaces one suggestion per
/// (open PR, workflow that ran on its head branch) — typically up to
/// `numPRs × numWorkflowsPerPR` rows. Filters out any suggestion the
/// user has already added.
private struct PipelineSuggestionsPopover: View {
    let prs: [PullRequest]
    let existingIDs: Set<String>
    let accentColor: Color
    let onAdd: (String) -> Void
    @State private var manualURL: String = ""
    @State private var suggestions: [WorkflowMonitor.Suggestion] = []
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    /// Per-row height (two text lines + padding + inter-row spacing),
    /// slightly generous so the exact-fit case never clips the last row.
    private static let rowHeight: CGFloat = 36

    /// The filtered list — drops suggestions the user already added,
    /// matched by the parsed PipelineSpec id.
    private var visibleSuggestions: [WorkflowMonitor.Suggestion] {
        suggestions.filter { s in
            guard let parsed = PipelineSpec.parse(s.url) else { return true }
            return !existingIDs.contains(parsed.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD PIPELINE")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)
            HStack(spacing: 6) {
                TextField("Paste workflow or run URL", text: $manualURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)
                Button("Add") {
                    let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, PipelineSpec.parse(trimmed) != nil {
                        onAdd(trimmed); manualURL = ""; dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Divider().background(Color.white.opacity(0.06))
            Text("FROM OPEN PRs")
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)
            if loading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).colorScheme(.dark)
                    Text("Looking up pipelines for each open PR…")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.5))
                }
            } else if visibleSuggestions.isEmpty {
                Text(suggestions.isEmpty
                     ? "No workflow runs found on any open PR head branch."
                     : "All of these are already being tracked.")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                // Grow to fit the suggestions, up to 8 rows tall, then
                // scroll. A bare ScrollView has no intrinsic content height,
                // so inside a popover it collapses to ~one row — hence the
                // explicit, row-count-driven height instead of a maxHeight.
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleSuggestions) { s in
                            SuggestionRow(suggestion: s,
                                          accentColor: accentColor,
                                          onAdd: {
                                              onAdd(s.url)
                                          })
                        }
                    }
                }
                .frame(height: CGFloat(min(visibleSuggestions.count, 8)) * Self.rowHeight)
            }
        }
        .padding(14)
        .frame(width: 420)
        .onAppear { loadSuggestions() }
    }

    private func loadSuggestions() {
        loading = true
        WorkflowMonitor.shared.fetchSuggestions(for: prs) { results in
            suggestions = results
            loading = false
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: WorkflowMonitor.Suggestion
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Dot reflecting the LAST run's conclusion — gives a hint of
            // whether this pipeline is currently green/red without
            // having to click in.
            Circle().fill(conclusionColor)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(suggestion.workflowName)
                        .monitorFont(size: 11)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(suggestion.workflowFile)
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.4))
                        .lineLimit(1)
                }
                Text("\(suggestion.pr.repoFullName)#\(suggestion.pr.number)  ·  \(suggestion.branch)")
                    .monitorFont(size: 9)
                    .foregroundColor(accentColor.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Add") { onAdd() }
                .buttonStyle(.plain)
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .cornerRadius(3)
        }
        .padding(.vertical, 2)
    }

    private var conclusionColor: Color {
        switch suggestion.mostRecentConclusion {
        case "success": return Color.onyxGreen
        case "failure", "timed_out", "cancelled", "action_required":
            return Color.onyxRed
        case "skipped": return Color.gray.opacity(0.5)
        case nil: return Color.onyxBlue   // in progress
        default: return Color.gray.opacity(0.4)
        }
    }
}

