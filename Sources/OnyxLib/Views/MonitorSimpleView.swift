import SwiftUI

// MARK: - Simple Monitor view
//
// "S" toggles a stripped-down layout: same headline at top, then giant
// CPU + MEM + GPU charts, a compact strip of the top-CPU containers,
// and a small weekly Timing tile in the bottom-right. Designed for
// at-a-glance ambient monitoring rather than the full diagnostic
// dashboard.

struct SimpleMonitorBody: View {
    @ObservedObject var appState: AppState
    @ObservedObject var monitor: MonitorManager
    @ObservedObject var dockerStats: DockerStatsManager
    @ObservedObject var timing: TimingManager
    let accentColor: Color
    /// Own reminders manager just for the due-today / due-tomorrow scope
    /// counts (list-independent, so it needs no selectedLists wiring).
    @StateObject private var reminders = RemindersManager()

    var body: some View {
        GeometryReader { geo in
            // Reserve a fixed strip for containers + timing tile, give
            // the rest to the charts. CPU gets the lion's share; MEM
            // and GPU split the bottom portion of the chart area.
            // Reserve enough height for the TALLEST member of the centered
            // bottom row — the weekly Timing tile (ratio bar + the hours
            // number + the per-day line + padding is ~60pt). The row is
            // center-aligned, so if the reserve is shorter than a member it
            // overflows symmetrically and the bottom half spills off the
            // window edge. The extra headroom keeps every member fully on
            // screen with a small margin.
            let bottomStripHeight: CGFloat = 78
            let chartArea = max(0, geo.size.height - bottomStripHeight - 16)
            let cpuHeight = chartArea * 0.55
            let subHeight = max(40, chartArea * 0.42)

            VStack(alignment: .leading, spacing: 8) {
                // CPU chart — giant.
                let cpuData = monitor.bucketedCPU()
                if !cpuData.isEmpty {
                    GridChart(title: "CPU", values: cpuData,
                              accentColor: Color.onyxBlue,
                              height: cpuHeight)
                } else {
                    CPUUnavailableCard(
                        message: monitor.cpuDiagnostic
                            ?? "CPU usage unavailable on this host.",
                        height: cpuHeight
                    )
                }

                // MEM and GPU side by side. Render whichever are
                // available; if neither, the row is just empty space.
                let memData = monitor.showMemoryChart ? monitor.bucketedMemory() : []
                let gpuData = monitor.bucketedGPU()
                let hasMem = !memData.isEmpty && monitor.showMemoryChart
                let hasGpu = !gpuData.isEmpty
                if hasMem || hasGpu {
                    HStack(spacing: 12) {
                        if hasMem {
                            GridChart(title: "MEMORY", values: memData,
                                      accentColor: Color.onyxAmber,
                                      height: subHeight)
                                .frame(maxWidth: .infinity)
                        }
                        if hasGpu {
                            GridChart(title: "GPU", values: gpuData,
                                      accentColor: Color.onyxPurple,
                                      height: subHeight)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Bottom strip: reminders due-scope counts and top-CPU
                // containers on the left, then the compact pipeline activity
                // indicators, then the weekly Timing tile flush trailing.
                HStack(alignment: .center, spacing: 12) {
                    SimpleRemindersScope(reminders: reminders)
                    SimpleContainersStrip(dockerStats: dockerStats)
                    Spacer(minLength: 12)
                    SimpleSessionActivityStrip(appState: appState)
                    SimplePipelinesStrip()
                    if timing.isConfigured {
                        WeeklyTimingTile(timing: timing, accentColor: accentColor)
                    }
                }
                .frame(height: bottomStripHeight)
            }
        }
    }
}

/// Simple-mode reminders scope: the same due-today / due-by-tomorrow
/// totals shown above the full reminders list, but standalone (no list)
/// so the two numbers stay visible at a glance in the stripped-down view.
/// Empty (zero-height) until Reminders access is granted.
struct SimpleRemindersScope: View {
    @ObservedObject var reminders: RemindersManager

    var body: some View {
        if reminders.accessGranted {
            HStack(spacing: 8) {
                chip(reminders.dueTodayCount, "today", Color.onyxRed)
                chip(reminders.dueTomorrowCount, "by tmrw", Color.onyxAmber)
            }
        } else {
            EmptyView()
        }
    }

    private func chip(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .monitorFont(size: 13, weight: .medium)
                .foregroundColor(color)
            Text(label)
                .monitorFont(size: 9)
                .foregroundColor(.gray.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}

/// Up to 3 containers with the highest current CPU%, rendered as a
/// compact horizontal strip. Empty (zero-height) when docker isn't
/// available so the timing tile sits flush against the leading edge.
struct SimpleContainersStrip: View {
    @ObservedObject var dockerStats: DockerStatsManager

    var body: some View {
        if dockerStats.isAvailable {
            let top = dockerStats.visibleContainers
                .sorted { DockerStatsManager.parseCPUPct($0.cpu) > DockerStatsManager.parseCPUPct($1.cpu) }
                .prefix(3)
            // Match the full list: bar saturates at total-cores × 100% so
            // a single hot container on a many-core box is correctly dim.
            let maxPct = CGFloat(max(1, dockerStats.cpuCores)) * 100.0
            HStack(spacing: 10) {
                ForEach(Array(top), id: \.id) { c in
                    SimpleContainerPill(
                        name: c.name,
                        cpuText: c.cpu,
                        cpuPct: CGFloat(DockerStatsManager.parseCPUPct(c.cpu)),
                        maxPct: maxPct
                    )
                }
            }
        } else {
            EmptyView()
        }
    }
}

/// One pill in the simple-mode containers strip. Renders the same
/// proportional CPU bar + color ramp as the full DockerStatsSection row,
/// just compacted into a chip-sized container.
private struct SimpleContainerPill: View {
    let name: String
    let cpuText: String
    let cpuPct: CGFloat
    let maxPct: CGFloat

    var body: some View {
        let color = monitorCPUBarColor(cpuPct, maxPct: maxPct)
        HStack(spacing: 6) {
            Text(name)
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(monitorCompactCPU(cpuText))
                .monitorFont(size: 11)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.04)
                    let fraction = min(cpuPct / maxPct, 1.0)
                    Rectangle()
                        .fill(color.opacity(0.22))
                        .frame(width: geo.size.width * fraction)
                }
            }
        )
        .cornerRadius(4)
    }
}

/// Compact strip of pipeline activity indicators for simple mode. One
/// chip per tracked pipeline, showing just the in-progress and succeeded
/// job counts (same icons/colors as the full PIPELINES list) so you can
/// tell at a glance whether anything is running. No labels — hover for
/// the workflow name + branch. Zero-height when nothing is tracked.
struct SimplePipelinesStrip: View {
    @ObservedObject private var monitor = WorkflowMonitor.shared
    @ObservedObject private var glMonitor = GitLabPipelineMonitor.shared

    private var merged: [PipelineStatus] { monitor.pipelines + glMonitor.pipelines }

    var body: some View {
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
private struct SimplePipelinePill: View {
    let status: PipelineStatus

    var body: some View {
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

// MARK: - Session output-activity (shared visual language)

/// Green when output is fresh, amber while winding down, grey once a
/// session has been quiet long enough to read as idle. Shared by the full
/// session-notes rows and the simple-mode activity strip.
func monitorSessionActivityColor(_ idleSeconds: TimeInterval) -> Color {
    if idleSeconds < 15 { return Color.onyxGreen }
    if idleSeconds < 120 { return Color.onyxAmber }
    return .gray.opacity(0.45)
}

/// Waveform while actively printing, "asleep" once quiet.
func monitorSessionActivityIcon(_ idleSeconds: TimeInterval) -> String {
    idleSeconds < 15 ? "waveform" : "moon.zzz"
}

/// Simple-mode strip of session output-activity pills — one per noted
/// session that has a terminal-output reading. Icon + colour only (no note
/// text; hover for it), mirroring SimplePipelinesStrip so the two read the
/// same. Sits just left of the pipeline pills in the bottom-right.
struct SimpleSessionActivityStrip: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var notesStore = SessionNotesStore.shared
    @ObservedObject private var activity = TerminalActivityStore.shared

    var body: some View {
        let entries = notesStore.activeNotes(in: appState.allSessions)
            .filter { activity.lastOutput(for: $0.session.id) != nil }
        if !entries.isEmpty {
            HStack(spacing: 8) {
                ForEach(entries, id: \.session.id) { entry in
                    SimpleSessionActivityPill(session: entry.session, note: entry.note)
                }
            }
        } else {
            EmptyView()
        }
    }
}

private struct SimpleSessionActivityPill: View {
    let session: TmuxSession
    let note: SessionNote

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let last = TerminalActivityStore.shared.lastOutput(for: session.id) {
                let idle = context.date.timeIntervalSince(last)
                Image(systemName: monitorSessionActivityIcon(idle))
                    .font(.system(size: 15))
                    .foregroundColor(monitorSessionActivityColor(idle))
                    .frame(width: 21)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(5)
                    .help("\(session.displayLabel) — \(note.text)\n"
                          + (idle < 15 ? "producing output" : "quiet for \(Int(idle))s"))
            }
        }
    }
}

