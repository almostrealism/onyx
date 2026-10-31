import SwiftUI
import EventKit
import OnyxCore
import OnyxUI

// MARK: - Simple Monitor view
//
// "S" toggles a stripped-down layout: same headline at top, then giant
// CPU + MEM + GPU charts, a compact strip of busy containers and PR jobs,
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
            //
            // With more than one Timing project each tile carries its
            // project's name too, a line taller.
            let bottomStripHeight = Self.bottomStripHeight(
                titledTimingTiles: (timing.isConfigured && timing.groups.count > 1) || timing.agents != nil,
                fontScale: fontScale)
            let chartArea = max(0, geo.size.height - bottomStripHeight - 16)
            let showsSubRow = (monitor.showMemoryChart && !monitor.bucketedMemory().isEmpty)
                || !monitor.bucketedGPU().isEmpty
            let single = MonitorChartLayout.singleHost(available: chartArea,
                                                       hasSubRow: showsSubRow,
                                                       fontScale: fontScale)
            let cpuHeight = single.cpu
            let subHeight = single.sub

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
                                       availableHeight: chartArea,
                                       maxRows: Self.maxFleetRows)
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
            // The charts and the side panel get exactly the area above the
            // strip, and nothing in them may run past it: anything that
            // did was drawn behind the strip's text and made both
            // unreadable. The arithmetic aims to fit; this guarantees it.
            .frame(height: chartArea, alignment: .top)
            .clipped()

            MonitorBottomStrip(appState: appState, reminders: reminders,
                               timing: timing, accentColor: accentColor,
                               showSessions: !showPanel,
                               height: bottomStripHeight) {
                MonitorWorkloadStrip(appState: appState, dockerStats: dockerStats,
                                     sidePanelOpen: showPanel)
            }
        }
    }
}

extension SimpleMonitorBody {
    /// Simple mode's per-host fleet charts stop at this many rows and go
    /// side by side: past three, one column never fit the screen.
    static let maxFleetRows = 3

    /// The bottom strip's height: room for its tallest member, the weekly
    /// Timing tile, plus a margin — the row is centered, so a member
    /// taller than the strip would spill up into the charts and off the
    /// bottom edge alike.
    static func bottomStripHeight(titledTimingTiles: Bool, fontScale: CGFloat) -> CGFloat {
        let base: CGFloat = 84 * fontScale
        guard titledTimingTiles else { return base }
        return base + MonitorChartLayout.lineHeight(9, fontScale: fontScale) + 5
    }
}

/// The strip along the bottom of every at-a-glance layout: what's due,
/// what's running, what's building, and the week's hours.
///
/// Shared by simple mode and both fleet layouts so they can't drift into
/// three slightly different answers to "what else is going on". The
/// workload slots are passed in, so a layout can choose its own sources.
struct MonitorBottomStrip<Workloads: View>: View {
    @ObservedObject var appState: AppState
    @ObservedObject var reminders: RemindersManager
    @ObservedObject var timing: TimingManager
    let accentColor: Color
    /// False when the side panel is up and already listing them, so the
    /// pills aren't saying it twice.
    let showSessions: Bool
    let height: CGFloat
    /// The workload slots — the one part that differs between layouts.
    @ViewBuilder let workloads: () -> Workloads

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 12) {
                SimpleRemindersScope(reminders: reminders)
                workloads()
                Spacer(minLength: 12)
                if showSessions {
                    SimpleSessionActivityStrip(appState: appState)
                }
                SimplePipelinesStrip()
                if timing.isConfigured {
                    // One tile per selected project, in the order chosen.
                    ForEach(timing.groups) { group in
                        WeeklyTimingTile(group: group, showsTitle: timing.groups.count > 1,
                                         accentColor: accentColor)
                    }
                }
                // Agent hours last, titled, in their own color: not yours.
                if let agents = timing.agents {
                    WeeklyTimingTile(group: agents, accentColor: accentColor, isAgents: true)
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

    /// Scrolls like the full layout's columns (indicators hidden, wheel
    /// and trackpad only): the column is held to the chart area, and a
    /// long list used to run under that edge with no way to reach it.
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 8)   // a little slack at the scroll end
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            SimpleSessionNotes(appState: appState, accentColor: accentColor)
            if Self.hasClaudeSessions(appState) {
                ClaudeSessionsSection(appState: appState, maxShown: 5)
            }
            if appState.appearance.agendaPane == .calendar {
                SimpleTodayCalendar(today: appState.today)
            } else {
                SimpleTodayReminders(today: appState.today, reminders: reminders,
                                     accentColor: accentColor,
                                     listOrder: appState.appearance.remindersLists)
            }
            SimplePullRequests(today: appState.today, accentColor: accentColor)
        }
    }

    static func hasClaudeSessions(_ appState: AppState) -> Bool {
        !appState.claudeSessions.activeSessions.isEmpty
            || !appState.claudeSessions.pendingPermissions.isEmpty
    }

    /// The column's width at a given UI font scale.
    ///
    /// Widened by a fifth when the PR lines arrived: a branch name and a
    /// pipeline step on one line is the widest thing the column carries,
    /// and at 260 both ends were truncating at once.
    static func columnWidth(fontScale: CGFloat) -> CGFloat { 312 * fontScale }

    /// The most of the window the column may take. The charts are what
    /// this layout is for, so they keep the clear majority — and pinning
    /// the SHARE rather than a multiple of the column means widening the
    /// column doesn't quietly raise the window size the panel needs
    /// (it stays ~780pt at 1×, as it was when the column was 260).
    static let maxColumnShare: CGFloat = 0.4

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
            && columnWidth(fontScale: fontScale) <= width * maxColumnShare
    }

    /// Whether the column has anything to say. Checked by the parent
    /// before the width is reserved — an empty 260pt gutter beside the
    /// charts is worse than no column at all.
    static func hasContent(appState: AppState, reminders: RemindersManager,
                           store: SessionNotesStore = .shared) -> Bool {
        if !orderedSessionNotes(appState: appState, store: store).isEmpty { return true }
        if hasClaudeSessions(appState) { return true }
        if !appState.today.visiblePullRequests().isEmpty { return true }
        // The calendar always has something to say, if only that the day
        // is clear or access is needed — and it's how you'd switch back.
        if appState.appearance.agendaPane == .calendar { return true }
        return reminders.accessGranted
            && reminders.reminders.contains(where: { RemindersManager.isDueToday($0) })
    }
}

/// Session notes for simple mode: a status dot, the ⌘N that reaches it,
/// and the note. No idle clock — the detailed overlay has the seconds;
/// here the color IS the status, which is all you can read at distance.
struct SimpleSessionNotes: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var notesStore = SessionNotesStore.shared
    @ObservedObject private var activity = TerminalActivityStore.shared
    let accentColor: Color
    @Environment(\.monitorFontScale) private var fontScale

    /// The column is shared with reminders, so sessions can't have all
    /// of it. Favorites come first, so the ones that overflow are the
    /// ones without a ⌘N anyway.
    private let maxShown = 6

    var body: some View {
        let entries = orderedSessionNotes(appState: appState, store: notesStore)
        if !entries.isEmpty {
            // One timeline for the whole list rather than one per row:
            // the dots only change color as idle time crosses 15s and
            // 120s, so a 5s tick is plenty and costs one invalidation.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text("SESSIONS")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(accentColor)
                        .tracking(2)

                    ForEach(Array(entries.prefix(maxShown)), id: \.session.id) { entry in
                        // Clickable here too. The detailed overlay's notes
                        // take you to the session; a compact view of the
                        // same list that only looks at you is a worse
                        // version of the same thing, and there is no
                        // reason for the two to disagree.
                        //
                        // `jumpToSession` rather than `switchToSession`:
                        // it routes through the terminal pool so the
                        // session's view actually activates, and drops the
                        // overlay covering it.
                        Button(action: {
                            appState.jumpToSession(entry.session,
                                                   dismissIfAlreadyActive: false)
                        }) {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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

    /// Gray when the session has never reported output — an unknown
    /// state reads as "not working", which is the safe way round.
    private func dotColor(for session: TmuxSession, now: Date) -> Color {
        guard let last = activity.lastOutput(for: session.id) else {
            return .gray.opacity(0.45)
        }
        return monitorSessionActivityColor(now.timeIntervalSince(last))
    }
}

/// The workload slots in the bottom strip: busy containers and PR jobs in
/// flight, as many as fit, ranked by the priority each reports.
///
/// Used to be the three busiest containers, always — even when every
/// container was idle and the thing worth watching was a PR's CI. Now
/// each kind of workload is a MonitorStripSource and MonitorStripRanker
/// picks; this view only gathers the data and draws the pills.
/// Zero-width when there's nothing to show.
struct MonitorWorkloadStrip: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dockerStats: DockerStatsManager
    /// Whether the side panel is up, listing PRs with their jobs.
    let sidePanelOpen: Bool
    @ObservedObject private var ghManager = PullRequestManager.shared
    @ObservedObject private var glManager = GitLabMergeRequestManager.shared
    @ObservedObject private var ci = PRPipelineMonitor.shared
    @ObservedObject private var workflowFilter = WorkflowFilterStore.shared
    /// Last time's choice, so a near-tie doesn't flicker (see stickiness).
    @State private var shownBefore: Set<String> = []

    var body: some View {
        let items = MonitorStripRanker.select(from: sources, in: context,
                                              shownBefore: shownBefore)
        HStack(spacing: 10) {
            ForEach(items) { item in
                switch item.content {
                case .container(let load):
                    SimpleContainerPill(name: load.name, cpuText: load.cpuText,
                                        cpuPct: CGFloat(load.cpuPercent),
                                        maxPct: CGFloat(load.maxPercent))
                case .prJob(let activity):
                    PRJobPill(activity: activity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: items.map(\.id))
        .onChange(of: items.map(\.id)) { ids in shownBefore = Set(ids) }
    }

    private var sources: [MonitorStripSource] {
        var sources: [MonitorStripSource] = []
        if dockerStats.isAvailable {
            // Match the full list: the bar saturates at total-cores × 100%
            // so a single hot container on a many-core box is correctly dim.
            let maxPct = Double(max(1, dockerStats.cpuCores)) * 100
            sources.append(ContainerStripSource(loads: dockerStats.visibleContainers.map {
                ContainerLoad(name: $0.name, cpuText: $0.cpu,
                              cpuPercent: DockerStatsManager.parseCPUPct($0.cpu),
                              maxPercent: maxPct)
            }))
        }
        sources.append(PRJobStripSource(
            prs: appState.today.orderedPullRequests(),
            runs: { ci.runs(for: $0) }))
        return sources
    }

    private var context: MonitorStripContext {
        MonitorStripContext(prsInSidePanel: sidePanelOpen
            ? Set(SimplePullRequests.shown(today: appState.today).map(\.id))
            : [])
    }
}

/// One pill in the simple-mode containers strip. Renders the same
/// proportional CPU bar + color ramp as the full DockerStatsSection row,
/// just compacted into a chip-sized container.
struct SimpleContainerPill: View {
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

// MARK: - Session output-activity (shared visual language)

/// Green when output is fresh, amber while winding down, gray once a
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
/// session that has a terminal-output reading. Icon + color only (no note
/// text; hover for it), mirroring SimplePipelinesStrip so the two read the
/// same. Sits just left of the pipeline pills in the bottom-right.
struct SimpleSessionActivityStrip: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var notesStore = SessionNotesStore.shared
    @ObservedObject private var activity = TerminalActivityStore.shared

    var body: some View {
        let entries = notesStore.activeNotes(in: appState.allSessions,
                                             keys: { appState.storageKeys(for: $0) })
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
