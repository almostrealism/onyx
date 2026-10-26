//
// TodayTiming.swift
//
// Responsibility: The week's hours as tiles — one per selected Timing
//                 project, and the agents' — the bottom strip's on the Mac
//                 and the top of the iPhone's Today page.
//
import SwiftUI
import OnyxCore

/// Weekly hours + per-day average for one selected Timing project (or All).
/// Simple mode shows one per selected project, side by side. Renders only
/// when that project has time this week.
public struct WeeklyTimingTile: View {
    let group: TimingManager.TimingGroup
    /// The project's name above the bar — only when there's more than one
    /// tile to tell apart.
    var showsTitle = false
    let accentColor: Color
    /// The agents tile: always titled, its number in the agents color,
    /// and drawn even for a week with no agent time.
    var isAgents = false

    public init(group: TimingManager.TimingGroup, showsTitle: Bool = false, accentColor: Color, isAgents: Bool = false) {
        self.group = group
        self.showsTitle = showsTitle
        self.accentColor = accentColor
        self.isAgents = isAgents
    }

    public var body: some View {
        let total = group.totalWeekHours
        let perDay = group.perDayThisWeek

        if total > 0 || isAgents {
            VStack(alignment: .trailing, spacing: 5) {
                if showsTitle || isAgents {
                    Text(group.title)
                        .monitorFont(size: 9, weight: .medium)
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Horizontal project-ratio bar across the top of the tile,
                // same visual as the vertical one beside the daily bars.
                // Drawn even for a single part — a solid bar in that
                // part's color. Beside other tiles, one without a bar
                // looked broken, and the color is what ties the tile to
                // the chart.
                if !group.projectTotals.isEmpty {
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
                Text(isAgents && total == 0 ? "0h" : formatHours(total))
                    .monitorFont(size: 18, weight: .light)
                    .foregroundColor(isAgents ? Color(hex: group.color) : accentColor)
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
            .help(isAgents ? Self.agentsHelp : "")
        }
    }

    /// What agent hours are, for the tile and the stats grid alike.
    public static let agentsHelp = "Agent hours: wall-clock time flowtree jobs ran, across every workstream. Jobs running in parallel each count in full, so this can exceed a day's 24 hours. Includes jobs still running. Not drawn in the bar chart, which is your time."

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

/// A fixed-extent stacked bar showing each project's share of the week's
/// total time — a linear "pie chart". Segments are sized proportional to
/// hours and colored per project, using the same palette as the day bars
/// so a color band can be followed between the two.
///
/// Vertical orientation stacks the largest project at the BOTTOM (matching
/// how the daily bars stack); horizontal places the largest at the LEADING
/// edge. `totals` is expected biggest-first (TimingManager.projectTotals).
public struct WeeklyTimeRatioBar: View {
    let totals: [TimingManager.ProjectTotal]
    var axis: Axis = .vertical
    /// Cross-axis size: width when vertical, height when horizontal.
    var thickness: CGFloat = 6
    /// Main-axis size: height when vertical, width when horizontal.
    var length: CGFloat = 96
    var cornerRadius: CGFloat = 2

    public init(totals: [TimingManager.ProjectTotal], axis: Axis = .vertical, thickness: CGFloat = 6, length: CGFloat = 96, cornerRadius: CGFloat = 2) {
        self.totals = totals
        self.axis = axis
        self.thickness = thickness
        self.length = length
        self.cornerRadius = cornerRadius
    }

    private var total: Double {
        max(totals.reduce(0) { $0 + $1.hours }, 0.0001)
    }

    public var body: some View {
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
