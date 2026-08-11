//
// FavoriteLayout.swift
//
// Responsibility: Lay the favorites forest out as nested rectangles that
//                 remain READABLE — the labels are the point of the boxes.
// Scope: Services layer. Pure geometry — no SwiftUI, no state.
//
// Why not a squarified treemap
// ----------------------------
// Squarified (Bruls et al.) minimises |aspect ratio − 1|. That is the
// wrong objective here. A cell has to hold a folder name, so what it
// needs is WIDTH: a 110×190 cell is beautifully square and shows "c…n",
// while a 300×30 cell is a terrible rectangle and perfectly readable.
// Optimising squareness spends the one scarce resource (width) to buy
// something worthless (height), which is how six siblings ended up as
// c…n / r…p / s…A while a third of the panel sat empty.
//
// The model
// ---------
// Width is fixed (the panel); height is free (the section scrolls, and
// there is usually slack). So we fix legibility as a HARD CONSTRAINT and
// minimise height:
//
//   * Every node has a minimum readable width, `minWidth`:
//       leaf      → icon + its label at the rendered font, clamped
//       container → max(its own label, widest child + padding)
//     The recursive case gives the invariant everything rests on:
//     **if a node gets at least its minWidth, so does every descendant.**
//
//   * Siblings are broken into rows, like line-breaking text. Within a
//     row each item takes its minWidth first, and the surplus is shared
//     out ∝ weight — the flexbox model. So a row FITS iff the sum of its
//     minimum widths fits, an exact test, no lay-out-and-check loop; and
//     where there is room to spare, a folder holding six favorites still
//     draws visibly bigger than one holding one.
//
//   * Which items share a row is chosen by dynamic programming over the
//     ordered siblings — dp[i] = min over j of dp[j] + height(row j..<i)
//     — giving the minimum total height with every cell legible. O(n²)
//     per level, and n is a handful.
//
// "Switch to vertical" is not a special case in any of this: a row that
// can only fit one item IS the vertical arrangement, and the DP reaches
// for it exactly when sharing would starve someone below their minimum.
//
// What this gives up: area is no longer strictly ∝ weight. Weight now
// drives *surplus* width and lets a row grow into spare vertical space.
// That trade is deliberate — an exactly-proportional illegible box is
// worth less than a readable one.
//

import Foundation
import CoreGraphics

/// One rendered box: where it goes, and what it stands for.
public struct PlacedFavorite: Identifiable, Equatable {
    public let path: String
    public let label: String
    /// False for boxes invented to disambiguate — they open like any
    /// folder, but they can't be "removed" because they were never saved.
    public let isFavorite: Bool
    public let hasChildren: Bool
    public let rect: CGRect
    public let depth: Int

    public var id: String { path }
}

public enum FavoriteTreemapLayout {

    // MARK: - Metrics
    //
    // These describe what the renderer actually draws. If the cell font or
    // padding changes in FavoritesTreemapView, change them here too or the
    // layout will promise room it doesn't deliver.

    /// Advance width of the cell font (11pt monospaced ≈ 0.6 em).
    public static let charWidth: CGFloat = 6.6
    /// Folder icon + inter-item spacing + horizontal padding in a cell.
    public static let labelChrome: CGFloat = 30
    /// No cell is narrower than this, however short its name.
    public static let minCellWidth: CGFloat = 66
    /// Nor wider than this on account of its name alone — past this a
    /// middle-truncated name is a fair trade for the space.
    public static let maxLabelWidth: CGFloat = 210
    /// A leaf cell's height: one line, comfortably pressable.
    public static let leafHeight: CGFloat = 34
    /// A container's title strip.
    public static let headerHeight: CGFloat = 22
    /// Inset from a container's edges to its children.
    public static let padding: CGFloat = 5
    /// Gutter between sibling boxes.
    public static let gap: CGFloat = 4

    // MARK: - Minimum readable width

    /// The narrowest this node can be drawn and still be worth drawing.
    ///
    /// For a container this includes the room its widest child needs, so
    /// a parent is never handed a width that dooms its children.
    ///
    /// `comfort` scales the requirement above the bare minimum. At 1.0
    /// cells are exactly readable and the layout is as short as possible;
    /// higher values buy breathing room by spending vertical space, which
    /// is what `place` does when the section has space going spare — ten
    /// columns that each *just* fit their name is legible but airless.
    public static func minWidth(_ node: FavoriteTreeNode,
                                comfort: CGFloat = 1) -> CGFloat {
        let text = charWidth * CGFloat(node.label.count) * comfort + labelChrome
        let ownLabel = min(max(text, minCellWidth), maxLabelWidth * comfort)
        guard !node.children.isEmpty else { return ownLabel }
        let widestChild = node.children.map { minWidth($0, comfort: comfort) }.max() ?? 0
        return max(ownLabel, widestChild + padding * 2)
    }

    /// Largest comfort factor whose layout still fits the height on offer.
    /// Required height is non-decreasing in comfort (wider minimums can
    /// only force more rows), so a bisection is exact to its tolerance.
    static func bestComfort(_ nodes: [FavoriteTreeNode],
                            width: CGFloat,
                            height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1 }
        var low: CGFloat = 1
        var high: CGFloat = 2.6
        guard requiredHeight(nodes, width: width, comfort: high) > height else { return high }
        for _ in 0..<7 {
            let mid = (low + high) / 2
            if requiredHeight(nodes, width: width, comfort: mid) <= height {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    /// Height this node needs at a given width, children included.
    public static func requiredHeight(_ node: FavoriteTreeNode,
                                      width: CGFloat,
                                      comfort: CGFloat = 1) -> CGFloat {
        guard !node.children.isEmpty else { return leafHeight }
        let inner = max(0, width - padding * 2)
        return headerHeight + requiredHeight(node.children, width: inner, comfort: comfort) + padding
    }

    /// Height a set of siblings needs at a given width — the DP's answer.
    public static func requiredHeight(_ nodes: [FavoriteTreeNode],
                                      width: CGFloat,
                                      comfort: CGFloat = 1) -> CGFloat {
        guard !nodes.isEmpty else { return 0 }
        let ordered = order(nodes)
        let rows = breakIntoRows(ordered, width: width, comfort: comfort)
        let heights = rows.map { rowHeight($0, width: width, comfort: comfort) }
        return heights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
    }

    // MARK: - Ordering

    /// Biggest first (the treemap convention), ties by path so the
    /// arrangement is stable between renders and between launches.
    static func order(_ nodes: [FavoriteTreeNode]) -> [FavoriteTreeNode] {
        nodes.sorted {
            $0.weight == $1.weight ? $0.path < $1.path : $0.weight > $1.weight
        }
    }

    // MARK: - Row breaking (the line-breaking DP)

    /// Widths for one row: everyone gets their minimum, then the surplus
    /// is shared ∝ weight. If even the minimums don't fit (a single item
    /// wider than the panel), everything is scaled down together — the
    /// labels truncate, but nothing is dropped.
    static func widths(_ row: [FavoriteTreeNode],
                       width: CGFloat,
                       comfort: CGFloat = 1) -> [CGFloat] {
        guard !row.isEmpty else { return [] }
        let usable = max(0, width - gap * CGFloat(row.count - 1))
        let mins = row.map { minWidth($0, comfort: comfort) }
        let minTotal = mins.reduce(0, +)
        guard minTotal > 0 else { return mins }
        if minTotal > usable {
            let scale = usable / minTotal
            return mins.map { $0 * scale }
        }
        let surplus = usable - minTotal
        let weightTotal = CGFloat(row.reduce(0) { $0 + $1.weight })
        guard weightTotal > 0 else { return mins }
        return zip(row, mins).map { node, min in
            min + surplus * CGFloat(node.weight) / weightTotal
        }
    }

    /// A row fits when its minimum widths plus gutters fit. Exact — no
    /// trial layout. A single item always "fits" (scaled down if need be)
    /// so there is always at least one legal partition.
    static func fits(_ row: [FavoriteTreeNode],
                     width: CGFloat,
                     comfort: CGFloat = 1) -> Bool {
        guard row.count > 1 else { return true }
        let usable = width - gap * CGFloat(row.count - 1)
        return row.map { minWidth($0, comfort: comfort) }.reduce(0, +) <= usable
    }

    /// Tallest item in the row, at the widths that row would give them.
    static func rowHeight(_ row: [FavoriteTreeNode],
                          width: CGFloat,
                          comfort: CGFloat = 1) -> CGFloat {
        let ws = widths(row, width: width, comfort: comfort)
        return zip(row, ws).map { requiredHeight($0, width: $1, comfort: comfort) }.max() ?? 0
    }

    /// Break siblings into rows so the total height is as small as
    /// possible while every cell keeps its minimum width.
    ///
    /// Classic line-breaking DP: dp[i] is the best total height for the
    /// first i items; a row from j..<i is only considered when it fits.
    /// Ties break toward fewer, fuller rows.
    static func breakIntoRows(_ nodes: [FavoriteTreeNode],
                              width: CGFloat,
                              comfort: CGFloat = 1) -> [[FavoriteTreeNode]] {
        let n = nodes.count
        guard n > 0 else { return [] }
        var dp = [CGFloat](repeating: .greatestFiniteMagnitude, count: n + 1)
        var back = [Int](repeating: 0, count: n + 1)
        dp[0] = 0

        for i in 1...n {
            for j in stride(from: i - 1, through: 0, by: -1) {
                let row = Array(nodes[j..<i])
                guard fits(row, width: width, comfort: comfort) else {
                    // Rows only grow from here — every wider candidate
                    // fails too, so stop scanning.
                    break
                }
                let cost = dp[j] + rowHeight(row, width: width, comfort: comfort) + (j > 0 ? gap : 0)
                if cost < dp[i] {
                    dp[i] = cost
                    back[i] = j
                }
            }
            // Safety net: a lone item is always legal.
            if dp[i] == .greatestFiniteMagnitude {
                let row = [nodes[i - 1]]
                dp[i] = dp[i - 1] + rowHeight(row, width: width, comfort: comfort) + (i > 1 ? gap : 0)
                back[i] = i - 1
            }
        }

        var rows: [[FavoriteTreeNode]] = []
        var i = n
        while i > 0 {
            let j = back[i]
            rows.append(Array(nodes[j..<i]))
            i = j
        }
        return rows.reversed()
    }

    // MARK: - Placement

    /// Place a forest into `rect`. Rows take the height they need; any
    /// surplus is shared ∝ weight so the layout fills the space it's
    /// given instead of leaving a dead band at the bottom.
    ///
    /// Every node always gets a box — nothing is ever dropped for being
    /// too small, because the width constraint is enforced up front.
    public static func place(_ nodes: [FavoriteTreeNode],
                             in rect: CGRect,
                             depth: Int = 0,
                             comfort: CGFloat? = nil) -> [PlacedFavorite] {
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        // Spend any spare height on wider cells. Decided once, at the top
        // level, and passed down so a container's children are laid out
        // to the same standard as their parent's siblings.
        let comfort = comfort ?? bestComfort(nodes, width: rect.width, height: rect.height)
        let ordered = order(nodes)
        let rows = breakIntoRows(ordered, width: rect.width, comfort: comfort)
        let rowHeights = rows.map { rowHeight($0, width: rect.width, comfort: comfort) }
        let needed = rowHeights.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1))
        let surplus = max(0, rect.height - needed)
        let weightTotal = CGFloat(ordered.reduce(0) { $0 + $1.weight })

        var boxes: [PlacedFavorite] = []
        var y = rect.minY

        for (row, baseHeight) in zip(rows, rowHeights) {
            let rowWeight = CGFloat(row.reduce(0) { $0 + $1.weight })
            let height = baseHeight
                + (weightTotal > 0 ? surplus * rowWeight / weightTotal : 0)
            let ws = widths(row, width: rect.width, comfort: comfort)
            var x = rect.minX

            for (node, w) in zip(row, ws) {
                let cell = CGRect(x: x, y: y, width: w, height: height)
                boxes.append(PlacedFavorite(path: node.path,
                                            label: node.label,
                                            isFavorite: node.isFavorite,
                                            hasChildren: !node.children.isEmpty,
                                            rect: cell,
                                            depth: depth))
                if !node.children.isEmpty {
                    let inner = CGRect(x: cell.minX + padding,
                                       y: cell.minY + headerHeight,
                                       width: max(0, cell.width - padding * 2),
                                       height: max(0, cell.height - headerHeight - padding))
                    boxes.append(contentsOf: place(node.children, in: inner,
                                                   depth: depth + 1, comfort: comfort))
                }
                x += w + gap
            }
            y += height + gap
        }

        return boxes
    }

    /// Height the section should give the treemap at a known width: what
    /// the layout actually needs, floored so a single favorite doesn't
    /// look lost. No guessing, no grow-and-retry — the DP already knows.
    public static func preferredHeight(for nodes: [FavoriteTreeNode],
                                       width: CGFloat,
                                       minimum: CGFloat = 96) -> CGFloat {
        guard width > 0, !nodes.isEmpty else { return minimum }
        return max(minimum, requiredHeight(nodes, width: width))
    }
}
