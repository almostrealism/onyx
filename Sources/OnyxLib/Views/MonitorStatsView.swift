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

/// Weekly hours + per-day average for the currently-filtered Timing
/// project. Renders only when timing is configured AND the current
/// week has any data.
struct WeeklyTimingTile: View {
    @ObservedObject var timing: TimingManager
    let accentColor: Color

    var body: some View {
        let total = timing.totalWeekHours
        let daysWithData = timing.dailyHours.filter { $0.hours > 0 }.count
        let perDay = daysWithData > 0 ? total / Double(daysWithData) : 0

        if total > 0 {
            VStack(alignment: .trailing, spacing: 5) {
                // Horizontal project-ratio bar across the top of the tile,
                // same visual as the vertical one beside the daily bars.
                if timing.projectTotals.count > 1 {
                    WeeklyTimeRatioBar(totals: timing.projectTotals,
                                       axis: .horizontal,
                                       thickness: 5,
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
    if v >= 100  { return String(format: "%.0f%%", v) }   // e.g. "150%"
    if v >= 10   { return String(format: "%.1f%%", v) }   // e.g. "12.3%"
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
        if v >= 100  { return String(format: "%.0f%@", v, unit) }    // "888G"
        if v >= 10   { return String(format: "%.1f%@", v, unit) }    // "12.3G"
        if v >= 1    { return String(format: "%.1f%@", v, unit) }    // "1.2G"
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

    private var avgPerDay: Double {
        let daysWithData = timing.dailyHours.filter { $0.hours > 0 }.count
        guard daysWithData > 0 else { return 0 }
        return timing.totalWeekHours / Double(daysWithData)
    }

    private var maxHours: Double {
        max(timing.dailyHours.map(\.hours).max() ?? 1, 1)
    }

    /// Bar-chart plot height. Matched to the heatmap grid's height
    /// (7 rows × 12pt cells + 6 × 2pt gaps = 96pt) so the bottom of
    /// the bars lines up with the bottom of the heatmap, and the day
    /// labels sit level with the heatmap legend. Taller bars also help
    /// the bars look less stubby/over-wide at common window sizes.
    private static let barAreaHeight: CGFloat = 96

    /// Consistent color palette for projects
    private static let projectColors = ["66CCFF", "6BFF8E", "FFD06B", "C06BFF", "FF6B6B", "FF6BCD", "6BFFD0"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TIME THIS WEEK")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(accentColor)
                    .tracking(2)

                if !timing.filterProjectID.isEmpty {
                    Text(timing.filterProjectName)
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(accentColor.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accentColor.opacity(0.1))
                        .cornerRadius(3)
                }

                Spacer()

                if timing.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .colorScheme(.dark)
                }
            }

            // Week bar chart: the weekly project-ratio bar, then the daily
            // bars. The ratio bar is exactly barAreaHeight tall and
            // top-aligned, so its bottom lines up with the bars' bottom.
            // (The 26-week heatmap moved to its own middle-column section.)
            HStack(alignment: .top, spacing: 8) {
                    if timing.projectTotals.count > 1 {
                        WeeklyTimeRatioBar(totals: timing.projectTotals,
                                           axis: .vertical,
                                           thickness: 6,
                                           length: Self.barAreaHeight)
                    }
                // Stacked bar chart: one bar per day, segments per project
                VStack(spacing: 2) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(timing.dailyHours) { day in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                if day.hours > 0 && day.projects.count > 1 {
                                    VStack(spacing: 0) {
                                        ForEach(day.projects) { slice in
                                            Rectangle()
                                                .fill(Color(hex: slice.color).opacity(0.75))
                                                .frame(height: max(1, CGFloat(slice.hours / maxHours) * Self.barAreaHeight))
                                        }
                                    }
                                    .cornerRadius(2)
                                } else {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(day.hours > 0 ? Color(hex: day.projects.first?.color ?? "66CCFF").opacity(0.7) : Color.white.opacity(0.04))
                                        .frame(height: max(2, CGFloat(day.hours / maxHours) * Self.barAreaHeight))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: Self.barAreaHeight)
                    HStack(spacing: 3) {
                        ForEach(timing.dailyHours) { day in
                            Text(day.dayLabel)
                                .monitorFont(size: 8)
                                .foregroundColor(.gray.opacity(0.4))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }  // end bar row (ratio bar + daily bars)

            // Project totals legend
            if timing.projectTotals.count > 1 {
                HStack(spacing: 8) {
                    ForEach(timing.projectTotals.prefix(5)) { proj in
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
                    Spacer()
                }
            }

            // Stats: two columns, big current number + small longer-range avg
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", timing.totalWeekHours))
                            .monitorFont(size: 18, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/wk", timing.avgHoursPerWeekLast4))
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(4w avg)")
                            .monitorFont(size: 8)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.1f", avgPerDay))
                            .monitorFont(size: 18, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text("hrs/day")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f hrs/day", timing.avgHoursPerDayLast30))
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.5))
                        Text("(30d avg)")
                            .monitorFont(size: 8)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }

                Spacer()
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

