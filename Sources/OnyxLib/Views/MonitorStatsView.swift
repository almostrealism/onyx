import SwiftUI

/// Color ramp for container CPU bars, shared between DockerStatsSection
/// (the full list) and SimpleContainersStrip (the simple-mode strip) so
/// both views use the same visual language: blue at low CPU, yellow in
/// the middle, red when a container is dominating the box. Thresholds
/// are fractions of `maxPct` (total cores × 100%), matching how the
/// full list interprets saturation.
func monitorCPUBarColor(_ pct: CGFloat, maxPct: CGFloat) -> Color {
    let fraction = pct / max(1, maxPct)
    if fraction > 0.8 { return Color.onyxRed }
    if fraction > 0.4 { return Color.onyxAmber }
    return Color.onyxBlue
}

/// Weekly hours + per-day average for one selected Timing project (or All).
/// Simple mode shows one per selected project, side by side. Renders only
/// when that project has time this week.
struct WeeklyTimingTile: View {
    let group: TimingManager.TimingGroup
    /// The project's name above the bar — only when there's more than one
    /// tile to tell apart.
    var showsTitle = false
    let accentColor: Color

    var body: some View {
        let total = group.totalWeekHours
        let perDay = group.perDayThisWeek

        if total > 0 {
            VStack(alignment: .trailing, spacing: 5) {
                if showsTitle {
                    Text(group.title)
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Horizontal project-ratio bar across the top of the tile,
                // same visual as the vertical one beside the daily bars.
                if group.projectTotals.count > 1 {
                    // Deliberately chunky. This is the only place the
                    // week's split across projects is shown in simple
                    // mode, and at 5pt the color bands were too fine to
                    // read at a glance — which is the whole job of a
                    // simple-mode tile.
                    WeeklyTimeRatioBar(totals: group.projectTotals,
                                       axis: .horizontal,
                                       thickness: 10,
                                       length: Self.contentWidth)
                }
                Text(formatHours(total))
                    .monitorFont(size: 18, weight: .light)
                    .foregroundColor(accentColor)
                HStack(spacing: 4) {
                    Text(formatHours(perDay))
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.7))
                    Text("/day")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }
            .frame(width: Self.contentWidth, alignment: .trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
            .cornerRadius(4)
        }
    }

    /// Fixed content width so the ratio bar and the numbers share an edge.
    private static let contentWidth: CGFloat = 84

    private func formatHours(_ h: Double) -> String {
        // 8.0 → "8h"; 8.5 → "8.5h"; 0.25 → "15m"
        if h < 1 {
            let mins = Int(round(h * 60))
            return "\(mins)m"
        }
        // Drop trailing .0
        let rounded = (h * 10).rounded() / 10
        if rounded == rounded.rounded(.down) {
            return "\(Int(rounded))h"
        }
        return String(format: "%.1fh", rounded)
    }
}

struct DockerStatsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dockerStats: DockerStatsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONTAINERS")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                let visCount = dockerStats.visibleContainers.count
                let totalCount = dockerStats.containers.count
                if totalCount > 0 {
                    Text(visCount == totalCount ? "\(totalCount)" : "\(visCount)/\(totalCount)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
                // Without this, "every container is listed" and "every
                // container is busy" look identical — which reads as the
                // idle filter being broken rather than switched off.
                if dockerStats.showAllContainers {
                    Text("· all")
                        .monitorFont(size: 10)
                        .foregroundColor(Color.onyxAmber.opacity(0.6))
                        .help("Showing every container, including idle ones. Turn off in Settings → MONITOR, or press C.")
                }
            }

            if dockerStats.containers.isEmpty {
                Text("No containers running")
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Header
                HStack(spacing: 0) {
                    Text("NAME")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("UP")
                        .frame(width: 38, alignment: .trailing)
                    Text("CPU")
                        .frame(width: 55, alignment: .trailing)
                    Text("MEM")
                        .frame(width: 80, alignment: .trailing)
                    Text("PIDs")
                        .frame(width: 35, alignment: .trailing)
                }
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(.gray.opacity(0.4))

                ForEach(dockerStats.visibleContainers.sorted { parseCPUPercent($0.cpu) > parseCPUPercent($1.cpu) }) { container in
                    let cpuPct = parseCPUPercent(container.cpu)
                    let confidence = appState.activeHost.map {
                        NetworkTopologyStore.shared.containerConfidence(hostID: $0.id, containerName: container.name)
                    } ?? 0
                    HStack(spacing: 0) {
                        Circle()
                            .fill(confidenceColor(confidence))
                            .frame(width: 5, height: 5)
                            .padding(.trailing, 4)
                        Text(container.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(container.uptime)
                            .frame(width: 38, alignment: .trailing)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.75)
                        Text(monitorCompactCPU(container.cpu))
                            .frame(width: 55, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.7)
                        Text(shortMem(container.memUsage))
                            .frame(width: 80, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.7)
                        Text(container.pids)
                            .frame(width: 35, alignment: .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.75)
                    }
                    .monitorFont(size: 11)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        GeometryReader { geo in
                            let maxPct = CGFloat(dockerStats.cpuCores) * 100.0
                            let fraction = min(cpuPct / maxPct, 1.0)
                            let barWidth = geo.size.width * fraction
                            Rectangle()
                                .fill(cpuBarColor(cpuPct, maxPct: maxPct).opacity(0.15))
                                .frame(width: barWidth)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    )
                    .cornerRadius(3)
                }

                // Hidden idle containers indicator
                let hiddenCount = dockerStats.hiddenIdleCount
                if hiddenCount > 0 {
                    Text("\(hiddenCount) container\(hiddenCount == 1 ? "" : "s") with <1% CPU (C to show)")
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Parse "12.34%" → 12.34
    private func parseCPUPercent(_ s: String) -> CGFloat {
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        return CGFloat(Double(cleaned) ?? 0)
    }

    /// Color ramp for CPU bar: forwards to the file-level helper so the
    /// simple-mode strip and the full list stay in lockstep.
    private func cpuBarColor(_ pct: CGFloat, maxPct: CGFloat) -> Color {
        monitorCPUBarColor(pct, maxPct: maxPct)
    }

    /// Confidence dot color: green >= 0.7, yellow >= 0.3, red < 0.3
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.7 { return Color.onyxGreen }
        if confidence >= 0.3 { return Color.onyxAmber }
        return Color.onyxRed
    }

    /// Shorten "12.34MiB / 7.656GiB" → "12M/7.7G".
    /// Forwards to the file-level `monitorShortMem` so the simple-mode
    /// strip and full list share one set of formatting rules.
    private func shortMem(_ s: String) -> String { monitorShortMem(s) }
}

/// Adaptive CPU formatting — fewer decimal places as the magnitude grows,
/// so we use the column width sensibly instead of burning four chars on
/// trailing zeros at high CPU. `7.66%` over `123.45%` is the same number
/// of characters; the eye-readable digits are what matters.
func monitorCompactCPU(_ s: String) -> String {
    let cleaned = s.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "%", with: "")
    guard let v = Double(cleaned) else { return s }
    if v >= 1000 { return String(format: "%.0f%%", v) }   // e.g. "1024%"
    if v >= 100 { return String(format: "%.0f%%", v) }   // e.g. "150%"
    if v >= 10 { return String(format: "%.1f%%", v) }   // e.g. "12.3%"
    return String(format: "%.2f%%", v)                    // e.g. "0.05%"
}

/// Adaptive memory formatting. Goal: every result is ≤ 4 chars + unit
/// letter, so a worst-case "9999M/9999G" fits the 80px column without
/// wrap or truncation. Bigger numbers drop more decimals.
func monitorShortMem(_ s: String) -> String {
    let parts = s.components(separatedBy: " / ")
    return parts.map(monitorCompactSize).joined(separator: "/")
}

func monitorCompactSize(_ part: String) -> String {
    let t = part.trimmingCharacters(in: .whitespaces)
    let suffixes: [(String, String)] = [
        ("GiB", "G"), ("MiB", "M"), ("KiB", "K"),
        ("GB",  "G"), ("MB",  "M"), ("KB",  "K"),
        ("B",   "B"),
    ]
    for (input, unit) in suffixes where t.hasSuffix(input) {
        let numStr = t.dropLast(input.count).trimmingCharacters(in: .whitespaces)
        guard let v = Double(numStr) else { return t }
        if v >= 1000 { return String(format: "%.0f%@", v / 1024, "T") }
        if v >= 100 { return String(format: "%.0f%@", v, unit) }    // "888G"
        if v >= 10 { return String(format: "%.1f%@", v, unit) }    // "12.3G"
        if v >= 1 { return String(format: "%.1f%@", v, unit) }    // "1.2G"
        return String(format: "%.2f%@", v, unit)                     // "0.12G"
    }
    return t
}

// MARK: - Weekly time ratio bar

/// A fixed-extent stacked bar showing each project's share of the week's
/// total time — a linear "pie chart". Segments are sized proportional to
/// hours and colored per project, using the same palette as the day bars
/// so a color band can be followed between the two.
///
/// Vertical orientation stacks the largest project at the BOTTOM (matching
/// how the daily bars stack); horizontal places the largest at the LEADING
/// edge. `totals` is expected biggest-first (TimingManager.projectTotals).
struct WeeklyTimeRatioBar: View {
    let totals: [TimingManager.ProjectTotal]
    var axis: Axis = .vertical
    /// Cross-axis size: width when vertical, height when horizontal.
    var thickness: CGFloat = 6
    /// Main-axis size: height when vertical, width when horizontal.
    var length: CGFloat = 96
    var cornerRadius: CGFloat = 2

    private var total: Double {
        max(totals.reduce(0) { $0 + $1.hours }, 0.0001)
    }

    var body: some View {
        // Vertical: largest at the bottom → render smallest-first, top-down.
        // Horizontal: largest at the leading edge → render biggest-first.
        let ordered = axis == .vertical ? Array(totals.reversed()) : totals
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    ForEach(ordered) { p in
                        Rectangle()
                            .fill(Color(hex: p.color).opacity(0.8))
                            .frame(height: CGFloat(p.hours / total) * length)
                    }
                }
                .frame(width: thickness, height: length)
            } else {
                HStack(spacing: 0) {
                    ForEach(ordered) { p in
                        Rectangle()
                            .fill(Color(hex: p.color).opacity(0.8))
                            .frame(width: CGFloat(p.hours / total) * length)
                    }
                }
                .frame(width: length, height: thickness)
            }
        }
        .cornerRadius(cornerRadius)
    }
}

// MARK: - Timing.app Chart

/// The weekly bar chart + stats half of the Timing.app data. Lives in the
/// left-most overlay column; the heatmap (TimingHeatmapSection) sits in the
/// middle column, since bar+stats is taller than the heatmap and pairing them
/// side-by-side wasted vertical space.
struct TimingBarSection: View {
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    /// Every bar in every group shares one scale, so a short day for one
    /// project reads as short beside a long day for another.
    private var maxHours: Double {
        max(timing.groups.flatMap { $0.dailyHours.map(\.hours) }.max() ?? 1, 1)
    }

    /// More than one project selected: label things by project.
    private var isMulti: Bool { timing.groups.count > 1 }

    /// Bar-chart plot height. Matched to the heatmap grid's height
    /// (7 rows × 12pt cells + 6 × 2pt gaps = 96pt) so the bottom of
    /// the bars lines up with the bottom of the heatmap, and the day
    /// labels sit level with the heatmap legend. Taller bars also help
    /// the bars look less stubby/over-wide at common window sizes.
    private static let barAreaHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("TIME THIS WEEK")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(accentColor)
                    .tracking(2)

                // The selected projects, in the order their bars stand in
                // each day. The dot is the color of the strip under each
                // of that project's bars.
                if !timing.filterProjectIDs.isEmpty {
                    ForEach(timing.groups) { group in
                        HStack(spacing: 3) {
                            if isMulti {
                                Circle()
                                    .fill(Color(hex: group.color))
                                    .frame(width: 5, height: 5)
                            }
                            Text(group.title)
                                .monitorFont(size: 9, weight: .medium)
                                .foregroundColor(accentColor.opacity(0.6))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accentColor.opacity(0.1))
                        .cornerRadius(3)
                    }
                }

                Spacer()

                if timing.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .colorScheme(.dark)
                }
            }

            // Week bar chart: the weekly project-ratio bar (all selected
            // projects together), then the days. Each day holds one bar per
            // selected project, side by side, in the order chosen.
            HStack(alignment: .top, spacing: 8) {
                if timing.projectTotals.count > 1 {
                    WeeklyTimeRatioBar(totals: timing.projectTotals,
                                       axis: .vertical,
                                       thickness: 6,
                                       length: Self.barAreaHeight)
                }
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: isMulti ? 6 : 3) {
                        ForEach(0..<7, id: \.self) { dayIndex in
                            HStack(alignment: .bottom, spacing: 1) {
                                ForEach(timing.groups) { group in
                                    if dayIndex < group.dailyHours.count {
                                        DayBar(day: group.dailyHours[dayIndex],
                                               maxHours: maxHours,
                                               height: Self.barAreaHeight,
                                               marker: isMulti ? Color(hex: group.color) : nil)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: Self.barAreaHeight + (isMulti ? 3 : 0))
                    HStack(spacing: isMulti ? 6 : 3) {
                        ForEach(timing.groups.first?.dailyHours ?? []) { day in
                            Text(day.dayLabel)
                                .monitorFont(size: 8)
                                .foregroundColor(.gray.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            // Legend: every subproject across the selected projects (and
            // the projects themselves, when time is logged to them
            // directly), most time first, whichever project it's under.
            if timing.projectTotals.count > 1 {
                FlowLayout(spacing: 8, lineSpacing: 3) {
                    ForEach(timing.projectTotals.prefix(isMulti ? 10 : 5)) { proj in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color(hex: proj.color))
                                .frame(width: 5, height: 5)
                            Text("\(proj.title)")
                                .monitorFont(size: 9)
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                            Text(String(format: "%.0fh", proj.hours))
                                .monitorFont(size: 9, weight: .medium)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }

            // Stats: per selected project, the week's hours and hours/day,
            // each with its longer-range average beneath.
            VStack(alignment: .leading, spacing: isMulti ? 6 : 0) {
                ForEach(timing.groups) { group in
                    TimingStatsRow(group: group, label: isMulti ? group.title : nil)
                }
            }

            if let error = timing.lastError {
                Text(error)
                    .monitorFont(size: 9)
                    .foregroundColor(Color.onyxRed.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }
}

/// One stacked bar: a day for one project, split by subproject. With more
/// than one project selected it stands on a thin strip of the project's
/// color, which is how the bars side by side are told apart.
private struct DayBar: View {
    let day: TimingManager.DailyTime
    let maxHours: Double
    let height: CGFloat
    let marker: Color?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if day.hours > 0 && day.projects.count > 1 {
                VStack(spacing: 0) {
                    ForEach(day.projects) { slice in
                        Rectangle()
                            .fill(Color(hex: slice.color).opacity(0.75))
                            .frame(height: max(1, CGFloat(slice.hours / maxHours) * height))
                    }
                }
                .cornerRadius(2)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(day.hours > 0
                          ? Color(hex: day.projects.first?.color ?? "66CCFF").opacity(0.7)
                          : Color.white.opacity(0.04))
                    .frame(height: max(2, CGFloat(day.hours / maxHours) * height))
            }
            if let marker {
                Rectangle()
                    .fill(marker.opacity(0.9))
                    .frame(height: 2)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The two numbers for one project: hours this week (with the 4-week
/// average) and hours per day (with the 30-day average). Labeled with the
/// project when more than one is shown.
private struct TimingStatsRow: View {
    let group: TimingManager.TimingGroup
    let label: String?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            if let label {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: group.color))
                        .frame(width: 6, height: 6)
                    Text(label)
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: 90, alignment: .leading)
                .padding(.top, 5)
            }
            stat(value: group.totalWeekHours, unit: "hrs",
                 average: String(format: "%.1f hrs/wk", group.avgHoursPerWeekLast4), span: "(4w avg)")
            stat(value: group.perDayThisWeek, unit: "hrs/day",
                 average: String(format: "%.1f hrs/day", group.avgHoursPerDayLast30), span: "(30d avg)")
            Spacer()
        }
    }

    private func stat(value: Double, unit: String, average: String, span: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(String(format: "%.1f", value))
                    .monitorFont(size: 18, weight: .medium)
                    .foregroundColor(.white.opacity(0.9))
                Text(unit)
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.5))
            }
            HStack(spacing: 3) {
                Text(average)
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.5))
                Text(span)
                    .monitorFont(size: 8)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
    }
}

/// Lays children out left to right, wrapping onto a new line when the row
/// is full. For the timing legend, which with several projects selected
/// has more entries than fit on one line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// The 26-week activity heatmap, centered in the middle overlay column. Split
/// out of the timing section so it can sit next to (rather than under) the
/// taller bar chart + stats, cutting wasted vertical space.
struct TimingHeatmapSection: View {
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("LAST 26 WEEKS")
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(accentColor)
                .tracking(2)

            if !timing.heatmap.isEmpty {
                TimingHeatmapGrid(weeks: timing.heatmap, anchorMonday: timing.heatmapAnchorMonday)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// 26×7 grid showing daily hours over the last 26 weeks (half a year), colored against a
/// 40-hour-week target. Colors encode how close a single day is to the
/// one-seventh-of-40 = 5.71-hour ceiling: black = no data, blue = light,
/// green = healthy, red = over-target.
struct TimingHeatmapGrid: View {
    let weeks: [[Double]]  // [week][day] — week 0 oldest, day 0 Monday
    let anchorMonday: Date  // Monday of the rightmost (current) week

    /// Reference hours for a "full" day under a 40-hour workweek.
    private static let dayReference: Double = 40.0 / 7.0

    /// Piecewise color ramp against the 40-hr-week target:
    ///   0%   → black
    ///   25%  → cold blue (low activity)
    ///   50%  → healthy green
    ///   75%  → red (at/over target)
    ///  100%+ → saturated red
    ///
    /// Between stops we interpolate linearly in RGB. 62.5% lands halfway
    /// between green (50%) and red (75%) — roughly half-green half-red.
    static func heatColor(hours: Double) -> Color {
        let t = min(max(hours / dayReference, 0), 1)
        // Stops: (threshold, r, g, b)
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.00, 0.00, 0.00),   // black
            (0.25, 0.15, 0.45, 0.95),   // cold blue
            (0.50, 0.20, 0.80, 0.40),   // healthy green
            (0.75, 1.00, 0.30, 0.20),   // red
            (1.00, 1.00, 0.20, 0.20)    // saturated red
        ]
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if t <= b.0 {
                let span = b.0 - a.0
                let frac = span > 0 ? (t - a.0) / span : 0
                return Color(
                    red: a.1 + (b.1 - a.1) * frac,
                    green: a.2 + (b.2 - a.2) * frac,
                    blue: a.3 + (b.3 - a.3) * frac
                )
            }
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
    }

    /// Fixed square cell size — guarantees the grid never stretches.
    /// Tuned so 7 rows of cells (with gaps) land close to the bar
    /// chart's 76pt height, so the two halves of the top row read as
    /// roughly equal weight instead of bar-huge / heatmap-tiny.
    private static let cellSize: CGFloat = 12
    private static let cellGap: CGFloat = 2

    private static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Sum of all 7 days for a given week column.
    private func weekTotal(_ week: Int) -> Double {
        weeks[week].reduce(0, +)
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// Compute the actual date for a cell.
    private func cellDate(week: Int, day: Int) -> Date {
        let weeksBack = (weeks.count - 1) - week
        let daysBack = weeksBack * 7 - day
        return Calendar.current.date(byAdding: .day, value: -daysBack, to: anchorMonday)!
    }

    /// A cell whose date is after today — a day that hasn't started yet.
    /// These exist only in the current (rightmost) week's column and
    /// should render as empty space, not a zero-hours black square.
    private func isFuture(week: Int, day: Int) -> Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: cellDate(week: week, day: day))
             > cal.startOfDay(for: Date())
    }

    /// "Wed Apr 2: 4.2 hrs · 28% of 15.0h week"
    private func tooltip(week: Int, day: Int) -> String {
        let hours = weeks[week][day]
        let total = weekTotal(week)
        let date = cellDate(week: week, day: day)
        let dayName = Self.dayNames[day]
        let dateStr = Self.tooltipDateFormatter.string(from: date)
        if total <= 0 {
            return String(format: "%@ %@: %.1f hrs", dayName, dateStr, hours)
        }
        let pct = hours / total * 100
        return String(format: "%@ %@: %.1f hrs · %.0f%% of %.1fh week",
                      dayName, dateStr, hours, pct, total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(spacing: Self.cellGap) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: Self.cellGap) {
                        ForEach(0..<weeks.count, id: \.self) { week in
                            let future = isFuture(week: week, day: day)
                            let hours = weeks[week][day]
                            RoundedRectangle(cornerRadius: 2)
                                // Future days haven't begun — render as empty
                                // space, like the gaps between cells, rather
                                // than a black "zero" square.
                                .fill(future ? Color.clear : Self.heatColor(hours: hours))
                                .frame(width: Self.cellSize, height: Self.cellSize)
                                .help(future ? "" : tooltip(week: week, day: day))
                        }
                    }
                }
            }
            // Legend directly under the grid, same width
            HStack(spacing: 3) {
                Text("26W")
                    .monitorFont(size: 8)
                    .foregroundColor(.gray.opacity(0.35))
                HStack(spacing: 0) {
                    ForEach(0..<32, id: \.self) { i in
                        Rectangle()
                            .fill(Self.heatColor(hours: Double(i) / 32 * Self.dayReference))
                            .frame(width: 4, height: 4)
                    }
                }
                Text("40h")
                    .monitorFont(size: 8)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
        .fixedSize()
    }
}
