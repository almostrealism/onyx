import SwiftUI
import EventKit

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
    @Environment(\.monitorFontScale) private var fontScale
    /// Shared with the fleet layouts (owned by MonitorView) so switching
    /// layouts doesn't spin up a second EventKit client and re-fetch. It
    /// stays in "Today" mode — no selectedLists wiring — which is exactly
    /// the scope these layouts want.
    @ObservedObject var reminders: RemindersManager
    /// Observed here, not just inside the panel: `showPanel` depends on
    /// whether any session has a note, and that decision also controls
    /// the pills in the bottom strip. Without this, adding the first note
    /// wouldn't open the column until some other change forced a redraw.
    @ObservedObject private var notesStore = SessionNotesStore.shared

    var body: some View {
        GeometryReader { geo in
            // Reserve a fixed strip for containers + timing tile, give
            // the rest to the charts. CPU gets the lion's share; MEM
            // and GPU split the bottom portion of the chart area.
            // Reserve enough height for the TALLEST member of the centered
            // bottom row — the weekly Timing tile (ratio bar + the hours
            // number + the per-day line + padding is ~65pt). The row is
            // center-aligned, so if the reserve is shorter than a member it
            // overflows symmetrically and the bottom half spills off the
            // window edge. The extra headroom keeps every member fully on
            // screen with a small margin.
            //
            // Scaled: the tile's contents are monitorFont-sized, so at a
            // larger UI font they grow while a fixed reserve would not —
            // and the row would start clipping.
            let bottomStripHeight: CGFloat = 84 * fontScale
            let chartArea = max(0, geo.size.height - bottomStripHeight - 16)
            let cpuHeight = chartArea * 0.55
            let subHeight = max(40, chartArea * 0.42)

            // The side panel — sessions above today's reminders — takes a
            // fixed column down the LEFT, sharing an edge with the
            // today/by-tmrw chips in the strip below, so the counts and the
            // things being counted line up. Charts keep whatever's left,
            // which is most of it.
            //
            // It only appears when there's room AND something to say: on a
            // narrow window the charts are the point, and squeezing them for
            // text would trade the thing you glance at for the thing you
            // read. An empty column is worse than no column.
            let panelColumn = SimpleSidePanel.columnWidth(fontScale: fontScale)
            let showPanel = SimpleSidePanel.shouldShow(
                appState: appState, reminders: reminders, store: notesStore,
                width: geo.size.width, fontScale: fontScale)

            HStack(alignment: .top, spacing: showPanel ? 20 : 0) {
                if showPanel {
                    SimpleSidePanel(appState: appState, reminders: reminders,
                                    accentColor: accentColor)
                        .frame(width: panelColumn, alignment: .topLeading)
                }

                // What the charts are OF is `F`, independent of this
                // layout being the terse one. Same panel, same strip,
                // different subject.
                switch appState.fleetMode {
                case .topHosts:
                    FleetStackedCharts(appState: appState, monitor: monitor,
                                       accentColor: accentColor,
                                       availableHeight: chartArea)
                case .fleetMax:
                    FleetMergedCharts(appState: appState, monitor: monitor,
                                      accentColor: accentColor,
                                      availableHeight: chartArea)
                case .currentHost:
                VStack(alignment: .leading, spacing: 8) {
                    // CPU chart — giant.
                    let cpuData = monitor.bucketedCPU()
                    if !cpuData.isEmpty {
                        GridChart(title: "CPU", values: cpuData,
                                  accentColor: Color.onyxBlue,
                                  height: cpuHeight)
                    } else {
                        // Prefer the actual poll failure: "CPU usage
                        // unavailable on this host" is misleading when the
                        // truth is that the stats command never ran.
                        CPUUnavailableCard(
                            message: monitor.latestSample == nil
                                ? (monitor.lastError ?? "Waiting for the first sample…")
                                : (monitor.cpuDiagnostic ?? "CPU usage unavailable on this host."),
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
                }
                }
            }

            MonitorBottomStrip(appState: appState, reminders: reminders,
                               timing: timing, accentColor: accentColor,
                               showSessions: !showPanel,
                               height: bottomStripHeight) {
                SimpleContainersStrip(dockerStats: dockerStats)
            }
        }
    }
}

/// The strip along the bottom of every at-a-glance layout: what's due,
/// what's running, what's building, and the week's hours.
///
/// Shared by simple mode and both fleet layouts so they can't drift into
/// three slightly different answers to "what else is going on". Only the
/// containers slot differs — one host's containers in simple mode, the
/// whole fleet's in the fleet layouts — so it's passed in.
struct MonitorBottomStrip<Containers: View>: View {
    @ObservedObject var appState: AppState
    @ObservedObject var reminders: RemindersManager
    @ObservedObject var timing: TimingManager
    let accentColor: Color
    /// False when the side panel is up and already listing them, so the
    /// pills aren't saying it twice.
    let showSessions: Bool
    let height: CGFloat
    @ViewBuilder let containers: () -> Containers

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 12) {
                SimpleRemindersScope(reminders: reminders)
                containers()
                Spacer(minLength: 12)
                if showSessions {
                    SimpleSessionActivityStrip(appState: appState)
                }
                SimplePipelinesStrip()
                if timing.isConfigured {
                    WeeklyTimingTile(timing: timing, accentColor: accentColor)
                }
            }
            .frame(height: height)
        }
    }
}

/// Simple mode's left column: session notes above today's reminders.
///
/// Both are "what's on my plate" in a view meant to be read from across
/// the room, so they share one column and one toggle (`D`). Off by
/// default — simple mode's whole point is the charts, and this is for
/// when you want the charts AND the plate.
struct SimpleSidePanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var reminders: RemindersManager
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SimpleSessionNotes(appState: appState, accentColor: accentColor)
            SimpleTodayReminders(reminders: reminders, accentColor: accentColor,
                                 listOrder: appState.appearance.remindersLists)
            Spacer(minLength: 0)
        }
    }

    /// The column's width at a given UI font scale.
    static func columnWidth(fontScale: CGFloat) -> CGFloat { 260 * fontScale }

    /// The full "should the column be up" decision, shared by every
    /// layout that offers it: the user's toggle, something to say, and
    /// room to say it in. On a narrow window the charts are the point,
    /// and squeezing them for text trades the thing you glance at for
    /// the thing you read.
    static func shouldShow(appState: AppState,
                           reminders: RemindersManager,
                           store: SessionNotesStore = .shared,
                           width: CGFloat,
                           fontScale: CGFloat) -> Bool {
        appState.appearance.simpleShowSidePanel
            && hasContent(appState: appState, reminders: reminders, store: store)
            && width > columnWidth(fontScale: fontScale) * 3
    }

    /// Whether the column has anything to say. Checked by the parent
    /// before the width is reserved — an empty 260pt gutter beside the
    /// charts is worse than no column at all.
    static func hasContent(appState: AppState, reminders: RemindersManager,
                           store: SessionNotesStore = .shared) -> Bool {
        if !orderedSessionNotes(appState: appState, store: store).isEmpty { return true }
        return reminders.accessGranted
            && reminders.reminders.contains(where: { RemindersManager.isDueToday($0) })
    }
}

/// Session notes for simple mode: a status dot, the ⌘N that reaches it,
/// and the note. No idle clock — the detailed overlay has the seconds;
/// here the colour IS the status, which is all you can read at distance.
struct SimpleSessionNotes: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var notesStore = SessionNotesStore.shared
    @ObservedObject private var activity = TerminalActivityStore.shared
    let accentColor: Color
    @Environment(\.monitorFontScale) private var fontScale

    /// The column is shared with reminders, so sessions can't have all
    /// of it. Favourites come first, so the ones that overflow are the
    /// ones without a ⌘N anyway.
    private let maxShown = 6

    var body: some View {
        let entries = orderedSessionNotes(appState: appState, store: notesStore)
        if !entries.isEmpty {
            // One timeline for the whole list rather than one per row:
            // the dots only change colour as idle time crosses 15s and
            // 120s, so a 5s tick is plenty and costs one invalidation.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSIONS")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(accentColor)
                        .tracking(2)

                    ForEach(Array(entries.prefix(maxShown)), id: \.session.id) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(dotColor(for: entry.session, now: context.date))
                                .frame(width: 7, height: 7)
                            if let n = entry.shortcut {
                                Text("⌘\(n)")
                                    .monitorFont(size: 9)
                                    .foregroundColor(.gray.opacity(0.45))
                            }
                            Text(entry.note.text)
                                .monitorFont(size: 13)
                                .foregroundColor(appState.activeSession?.id == entry.session.id
                                                 ? .white.opacity(0.95) : .white.opacity(0.8))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }

                    if entries.count > maxShown {
                        Text("+\(entries.count - maxShown) more")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }
            }
        }
    }

    /// Grey when the session has never reported output — an unknown
    /// state reads as "not working", which is the safe way round.
    private func dotColor(for session: TmuxSession, now: Date) -> Color {
        guard let last = activity.lastOutput(for: session.id) else {
            return .gray.opacity(0.45)
        }
        return monitorSessionActivityColor(now.timeIntervalSince(last))
    }
}

/// Today's reminders, listed down the left of simple mode.
///
/// Deliberately austere: simple mode is the across-the-room view, so this
/// answers one question — what am I doing today — and stops. No lists, no
/// per-item metadata beyond a time, and a hard cap with a "+N more" so a
/// heavy day can't push the charts around.
///
/// The manager backing simple mode runs in "Today" mode (no selected
/// lists), so `reminders.reminders` is already exactly what's due by end
/// of today, overdue included, across every list.
struct SimpleTodayReminders: View {
    @ObservedObject var reminders: RemindersManager
    let accentColor: Color
    /// The user's configured list order, so the groups read in the same
    /// sequence as the detailed overlay.
    let listOrder: [String]
    @Environment(\.monitorFontScale) private var fontScale

    /// Enough to be useful, few enough to stay readable at a distance.
    /// Counted across every group, not per group — three lists of five
    /// is still fifteen lines of text on a wall-mounted display.
    private let maxShown = 10

    var body: some View {
        let groups = reminders.todayGroupedByList(preferredOrder: listOrder)
        let total = groups.reduce(0) { $0 + $1.reminders.count }
        // Fill groups in order until the budget runs out, then drop the
        // rest. Truncating the LAST visible group rather than every group
        // keeps the earlier lists — the ones the user ordered first —
        // complete.
        var budget = maxShown
        var shown: [ReminderListGroup] = []
        for group in groups where budget > 0 {
            let take = Array(group.reminders.prefix(budget))
            budget -= take.count
            shown.append(ReminderListGroup(id: group.id, name: group.name, reminders: take))
        }

        return VStack(alignment: .leading, spacing: 9) {
            Text("TODAY")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)

            ForEach(shown, id: \.id) { group in
                VStack(alignment: .leading, spacing: 5) {
                    // One list gets no heading — the same rule the
                    // detailed view follows, where grouping only appears
                    // once there's more than one list to tell apart.
                    if shown.count > 1 {
                        Text(group.name.uppercased())
                            .monitorFont(size: 9, weight: .medium)
                            .foregroundColor(accentColor.opacity(0.6))
                            .tracking(1)
                    }

                    ForEach(group.reminders, id: \.calendarItemIdentifier) { reminder in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            // Overdue is the only distinction worth making here.
                            Circle()
                                .fill(isOverdue(reminder) ? Color.onyxRed : accentColor.opacity(0.55))
                                .frame(width: 5, height: 5)
                            Text(reminder.title ?? "Untitled")
                                .monitorFont(size: 13)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            if let time = timeLabel(reminder) {
                                Text(time)
                                    .monitorFont(size: 10)
                                    .foregroundColor(.gray.opacity(0.45))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
            }

            if total > maxShown {
                Text("+\(total - maxShown) more")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
    }

    /// A time only when the reminder has one — an all-day item shows
    /// nothing rather than a meaningless 00:00.
    private func timeLabel(_ reminder: EKReminder) -> String? {
        guard let c = reminder.dueDateComponents,
              let hour = c.hour, let minute = c.minute else { return nil }
        return String(format: "%d:%02d", hour, minute)
    }

    private func isOverdue(_ reminder: EKReminder) -> Bool {
        guard let c = reminder.dueDateComponents,
              let date = Calendar.current.date(from: c) else { return false }
        if c.hour != nil && c.minute != nil { return date < Date() }
        // All-day: only overdue once the whole day has passed.
        return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
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

