//
// TodayPipelines.swift
//
// Responsibility: Tracked pipelines at a glance — a pill per pipeline with
//                 its status dot and the counts that matter. Shared by the
//                 Mac and the iPhone.
//
import SwiftUI
import OnyxCore

/// Compact strip of pipeline activity indicators for simple mode. One
/// chip per tracked pipeline, showing just the in-progress and succeeded
/// job counts (same icons/colors as the full PIPELINES list) so you can
/// tell at a glance whether anything is running. No labels — hover for
/// the workflow name + branch. Zero-height when nothing is tracked.
public struct SimplePipelinesStrip: View {
    @ObservedObject private var monitor = WorkflowMonitor.shared
    @ObservedObject private var glMonitor = GitLabPipelineMonitor.shared

    private var merged: [PipelineStatus] { monitor.pipelines + glMonitor.pipelines }

    public init() {}

    public var body: some View {
        if !merged.isEmpty {
            HStack(spacing: 8) {
                ForEach(merged) { p in
                    SimplePipelinePill(status: p)
                }
            }
        } else {
            EmptyView()
        }
    }
}

/// One pill in the simple-mode pipeline strip: a status dot plus the
/// in-progress and succeeded counts. Other buckets (queued, skipped,
/// failed) are folded into the dot's color rather than shown as text —
/// this strip is purely an "is it active?" glance.
public struct SimplePipelinePill: View {
    let status: PipelineStatus

    public init(status: PipelineStatus) {
        self.status = status
    }

    public var body: some View {
        // Sized for at-a-glance reading from across the room (~50% larger
        // than the inline badges in the full PIPELINES list).
        //
        // Triage to at most two counts: the single most-relevant "active"
        // bucket (running, else queued, else failed) alongside the
        // completed/passing count. So a healthy finished pipeline shows
        // just the green check, while a busy one shows what it's doing —
        // never more than two slots. (The full list keeps every bucket.)
        HStack(spacing: 7) {
            PipelineStatusDot(overall: status.overall, size: 9)
            if status.inProgress > 0 {
                miniBadge("arrow.triangle.2.circlepath", status.inProgress,
                          color: Color.onyxBlue)
            } else if status.queued > 0 {
                miniBadge("hourglass", status.queued, color: Color.onyxAmber)
            } else if status.failed > 0 {
                miniBadge("xmark", status.failed, color: Color.onyxRed)
            }
            if status.succeeded > 0 {
                miniBadge("checkmark", status.succeeded, color: Color.onyxGreen)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .cornerRadius(5)
        .help(tooltip)
    }

    private func miniBadge(_ symbol: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 12))
            Text("\(count)")
                .monitorFont(size: 13)
        }
        .foregroundColor(color)
    }

    /// Branch from the resolved run, falling back to the branch named in a
    /// workflow spec's URL.
    private var branchTag: String? {
        if let b = status.headBranch, !b.isEmpty { return b }
        if case .workflow(_, let branch) = status.spec.target,
           let b = branch, !b.isEmpty { return b }
        return nil
    }

    /// "Build — owner/repo · feature-x · #315" (each piece only when known).
    private var tooltip: String {
        let name = status.title?.isEmpty == false
            ? status.title!
            : status.spec.displayName
        var meta = [status.spec.fullName]               // repo
        if let b = branchTag { meta.append(b) }          // branch
        if let n = status.runNumber { meta.append("#\(n)") }  // pipeline number
        return "\(name) — \(meta.joined(separator: " · "))"
    }
}

public struct PipelineStatusDot: View {
    let overall: PipelineOverallStatus
    var size: CGFloat = 6

    public init(overall: PipelineOverallStatus, size: CGFloat = 6) {
        self.overall = overall
        self.size = size
    }
    public var body: some View {
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
