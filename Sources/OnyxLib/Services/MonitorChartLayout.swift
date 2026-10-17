//
// MonitorChartLayout.swift
//
// Responsibility: How tall each chart in the at-a-glance monitor layouts
//                 may be, and how the per-host fleet charts are arranged
//                 into columns, so the chart area never runs past its
//                 budget into the strip along the bottom.
// Scope: Service. Pure arithmetic over sizes; no SwiftUI.
//
// The old arithmetic divided the budget among the chart BODIES and forgot
// that every GridChart carries a title line above its body, and that a
// stack's spacing is height too. Each of those is small, but there are
// several per host, so the shortfall grew with the fleet: the charts ran
// down behind the bottom strip's text, and a fleet of four or more never
// fit at all. Everything here counts the whole chart, title included.
//

import CoreGraphics

public enum MonitorChartLayout {

    /// Height of the line a monitorFont of `size` points occupies.
    /// Generous on purpose: overestimating leaves a few points of air,
    /// underestimating overlaps the strip below.
    public static func lineHeight(_ size: CGFloat, fontScale: CGFloat) -> CGFloat {
        (size * fontScale * 1.3).rounded(.up)
    }

    /// What a GridChart adds above its body: the 10pt title and the 4pt
    /// gap under it.
    public static func chartTitleHeight(fontScale: CGFloat) -> CGFloat {
        lineHeight(10, fontScale: fontScale) + 4
    }

    // MARK: Simple mode, one host

    /// CPU above, MEM/GPU side by side under it (when either is shown),
    /// split from `available` with the titles and the stack's spacing
    /// paid for first.
    public static func singleHost(available: CGFloat, hasSubRow: Bool,
                                  spacing: CGFloat = 8,
                                  fontScale: CGFloat) -> (cpu: CGFloat, sub: CGFloat) {
        let title = chartTitleHeight(fontScale: fontScale)
        guard hasSubRow else {
            return (max(40, available - title), 0)
        }
        let bodies = max(0, available - 2 * title - spacing)
        return (max(40, bodies * 0.57), max(30, bodies * 0.43))
    }

    // MARK: Fleet, one chart stack per host

    /// Columns and rows for `hosts` host stacks, no column taller than
    /// `maxRows`. Rows are as even as they can be: five hosts are 3 + 2,
    /// not 3 + 1 + 1.
    public static func fleetGrid(hosts: Int, maxRows: Int) -> (columns: Int, rows: Int) {
        guard hosts > 0 else { return (1, 0) }
        let cap = max(1, maxRows)
        let columns = (hosts + cap - 1) / cap
        let rows = (hosts + columns - 1) / columns
        return (columns, rows)
    }

    /// The host stacks split column-major into `columns` groups, the
    /// first ones filled first, preserving order — so the busiest hosts
    /// (FleetSeries ranks them) stay top-left.
    public static func columnsOf<T>(_ items: [T], columns: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let rows = (items.count + max(1, columns) - 1) / max(1, columns)
        return stride(from: 0, to: items.count, by: rows).map {
            Array(items[$0..<min($0 + rows, items.count)])
        }
    }

    /// The body height of each chart in a column of `rows` host stacks,
    /// each a header line and `chartsPerHost` charts.
    public static func fleetChartHeight(available: CGFloat, rows: Int, chartsPerHost: Int,
                                        rowSpacing: CGFloat, innerSpacing: CGFloat,
                                        fontScale: CGFloat, minChartHeight: CGFloat) -> CGFloat {
        guard rows > 0, chartsPerHost > 0 else { return minChartHeight }
        let header = lineHeight(11, fontScale: fontScale)
        let title = chartTitleHeight(fontScale: fontScale)
        let perRowFixed = header + CGFloat(chartsPerHost) * (title + innerSpacing)
        let fixed = CGFloat(rows) * perRowFixed + CGFloat(rows - 1) * rowSpacing
        let bodies = (available - fixed) / CGFloat(rows * chartsPerHost)
        return max(minChartHeight, bodies.rounded(.down))
    }

    // MARK: Fleet, merged

    /// Merged CPU (and GPU) chart bodies and the per-host memory bodies,
    /// from `available`. Memory keeps at most 30% (and 110pt, scaled); the
    /// merged charts are the headline and split what's left.
    public static func fleetMerged(available: CGFloat, hasGPU: Bool, hasMemory: Bool,
                                   spacing: CGFloat = 10,
                                   fontScale: CGFloat) -> (chart: CGFloat, memory: CGFloat) {
        let title = chartTitleHeight(fontScale: fontScale)
        // The "FLEET MAX — N HOSTS" line, and the GPU slot — a chart, or
        // the two-line "no GPU" note, about a title's worth less.
        var fixed = lineHeight(9, fontScale: fontScale) + spacing
        fixed += title + spacing
        if !hasGPU {
            fixed += lineHeight(10, fontScale: fontScale) + lineHeight(10, fontScale: fontScale) + spacing
        }

        var memory: CGFloat = 0
        if hasMemory {
            let section = min(110 * fontScale, available * 0.3)
            // Host label, 2pt gap, chart title; the rest is chart.
            let memFixed = lineHeight(9, fontScale: fontScale) + 2 + title
            memory = max(20, section - memFixed)
            fixed += section + spacing
        }
        if hasGPU { fixed += title + spacing }

        let charts = hasGPU ? 2 : 1
        let chart = max(30, ((available - fixed) / CGFloat(charts)).rounded(.down))
        return (chart, memory)
    }
}
