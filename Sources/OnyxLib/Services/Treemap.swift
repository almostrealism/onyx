//
// Treemap.swift
//
// Responsibility: Squarified treemap layout, and the recursive placement
//                 of a FavoriteTreeNode forest into positioned rects.
// Scope: Services layer. Pure geometry — no SwiftUI, no state.
//
// Squarified (Bruls, Huizing & van Wijk 2000): lay items out in rows
// along the shorter side, extending a row while doing so keeps its worst
// aspect ratio closer to 1. The point is cells that are near-square, so
// they work as *buttons* — long thin slivers can't hold a folder name.
//

import Foundation
import CoreGraphics

public enum Treemap {

    /// Lay `weights` out in `rect`, returning one rect per weight **in the
    /// caller's order**. Areas are proportional to the weights and the
    /// output exactly tiles `rect` (no gaps, no overlaps) — insets for
    /// visual gutters are the renderer's job.
    ///
    /// Zero/negative weights are treated as a small positive so nothing
    /// silently disappears.
    public static func layout(weights: [Double], in rect: CGRect) -> [CGRect] {
        guard !weights.isEmpty else { return [] }
        guard rect.width > 0, rect.height > 0 else {
            return Array(repeating: .zero, count: weights.count)
        }
        let safe = weights.map { $0.isFinite && $0 > 0 ? $0 : 0.0001 }
        let total = safe.reduce(0, +)

        // Biggest first makes the layout squarer; ties keep input order so
        // the arrangement is stable between renders.
        let order = safe.indices.sorted {
            safe[$0] == safe[$1] ? $0 < $1 : safe[$0] > safe[$1]
        }
        // Weights → areas in points².
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { safe[$0] * scale }

        var result = [CGRect](repeating: .zero, count: weights.count)
        var remaining = rect
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row: [Double] = [areas[index]]
            var next = index + 1
            // Extend the row while the worst aspect ratio keeps improving.
            while next < areas.count {
                let candidate = row + [areas[next]]
                if worstRatio(candidate, side: side) <= worstRatio(row, side: side) {
                    row = candidate
                    next += 1
                } else {
                    break
                }
            }
            let rowArea = row.reduce(0, +)
            let horizontal = remaining.width >= remaining.height
            // Thickness of the strip this row occupies.
            let thickness = side > 0 ? CGFloat(rowArea / side) : 0

            var offset: CGFloat = 0
            for (i, area) in row.enumerated() {
                let fraction = rowArea > 0 ? CGFloat(area / rowArea) : 0
                let cell: CGRect
                if horizontal {
                    // Row runs down the left edge of what's left.
                    let h = i == row.count - 1
                        ? remaining.maxY - (remaining.minY + offset)
                        : remaining.height * fraction
                    cell = CGRect(x: remaining.minX, y: remaining.minY + offset,
                                  width: thickness, height: h)
                    offset += h
                } else {
                    // Row runs across the top of what's left.
                    let w = i == row.count - 1
                        ? remaining.maxX - (remaining.minX + offset)
                        : remaining.width * fraction
                    cell = CGRect(x: remaining.minX + offset, y: remaining.minY,
                                  width: w, height: thickness)
                    offset += w
                }
                result[order[index + i]] = cell
            }

            if horizontal {
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness),
                                   height: remaining.height)
            } else {
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width,
                                   height: max(0, remaining.height - thickness))
            }
            index += row.count
        }

        return result
    }

    /// Worst (largest) aspect ratio in a row laid along `side`.
    private static func worstRatio(_ areas: [Double], side: Double) -> Double {
        guard side > 0, !areas.isEmpty else { return .greatestFiniteMagnitude }
        let sum = areas.reduce(0, +)
        guard sum > 0 else { return .greatestFiniteMagnitude }
        let maxA = areas.max() ?? 0
        let minA = areas.min() ?? 0
        guard minA > 0 else { return .greatestFiniteMagnitude }
        let s2 = side * side
        let sum2 = sum * sum
        return max(s2 * maxA / sum2, sum2 / (s2 * minA))
    }
}

// MARK: - Placing the favorites forest

/// One rendered box: where it goes, and what it stands for.
public struct PlacedFavorite: Identifiable, Equatable {
    public let path: String
    public let label: String
    /// False for boxes we invented to disambiguate — they open like any
    /// folder, but they can't be "removed" because they were never saved.
    public let isFavorite: Bool
    public let hasChildren: Bool
    public let rect: CGRect
    public let depth: Int

    public var id: String { path }
}

public enum FavoriteTreemapLayout {

    /// Height of a container's title strip. Children are placed below it,
    /// so the parent stays clickable even when packed with children.
    public static let headerHeight: CGFloat = 20
    /// Gutter between sibling boxes.
    public static let gap: CGFloat = 4
    /// Inset from a container's edges to its children.
    public static let padding: CGFloat = 4
    /// Below this, a container has no room to show children legibly, so
    /// they're dropped and it renders as a single box. `truncated` reports
    /// whether that happened so the UI can say so rather than silently
    /// hiding a favorite.
    public static let minChildArea: CGSize = CGSize(width: 54, height: 26)

    /// Recursively place a forest. Output is parents-before-children, so
    /// rendering in order puts children on top of their container.
    public static func place(_ nodes: [FavoriteTreeNode],
                             in rect: CGRect,
                             depth: Int = 0) -> (boxes: [PlacedFavorite], truncated: Bool) {
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return ([], false) }

        let rects = Treemap.layout(weights: nodes.map { Double($0.weight) }, in: rect)
        var boxes: [PlacedFavorite] = []
        var truncated = false

        for (node, raw) in zip(nodes, rects) {
            let cell = raw.insetBy(dx: gap / 2, dy: gap / 2)
            guard cell.width > 0, cell.height > 0 else {
                truncated = truncated || !node.children.isEmpty || node.isFavorite
                continue
            }

            let inner = CGRect(x: cell.minX + padding,
                               y: cell.minY + headerHeight,
                               width: cell.width - padding * 2,
                               height: cell.height - headerHeight - padding)
            let roomForChildren = !node.children.isEmpty
                && inner.width >= minChildArea.width
                && inner.height >= minChildArea.height

            boxes.append(PlacedFavorite(path: node.path,
                                        label: node.label,
                                        isFavorite: node.isFavorite,
                                        hasChildren: node.children.isEmpty ? false : roomForChildren,
                                        rect: cell,
                                        depth: depth))

            if roomForChildren {
                let sub = place(node.children, in: inner, depth: depth + 1)
                boxes.append(contentsOf: sub.boxes)
                truncated = truncated || sub.truncated
            } else if !node.children.isEmpty {
                truncated = true
            }
        }

        return (boxes, truncated)
    }

    /// The height to actually render at: start from `preferredHeight` and
    /// grow until no container is too cramped to show its children.
    ///
    /// This is what keeps the treemap honest — a nested favorite that
    /// doesn't fit isn't drawn at all, so rather than hiding one we make
    /// room and let the section scroll.
    public static func fittingHeight(for nodes: [FavoriteTreeNode],
                                     width: CGFloat,
                                     cap: CGFloat = 900) -> CGFloat {
        guard !nodes.isEmpty, width > 0 else {
            return preferredHeight(for: nodes, width: width)
        }
        var height = preferredHeight(for: nodes, width: width)
        for _ in 0..<8 {
            let placed = place(nodes, in: CGRect(x: 0, y: 0, width: width, height: height))
            if !placed.truncated || height >= cap { break }
            height = min(cap, height * 1.35)
        }
        return height
    }

    /// Height to give the treemap at a known width so cells stay big
    /// enough to read and press. Grows with the number of favorites (and
    /// a little with nesting depth, which spends space on headers); the
    /// caller scrolls when this exceeds the space it has.
    public static func preferredHeight(for nodes: [FavoriteTreeNode],
                                       width: CGFloat,
                                       minimum: CGFloat = 96) -> CGFloat {
        guard width > 0, !nodes.isEmpty else { return minimum }
        let all = FavoriteTree.flatten(nodes)
        let leaves = max(1, all.filter { $0.children.isEmpty }.count)
        let containers = all.count - leaves
        let targetCellArea: CGFloat = 108 * 34
        // Containers spend a header strip plus padding on themselves.
        let overhead = CGFloat(containers) * (headerHeight + padding * 2) * width / max(width, 1)
        let area = CGFloat(leaves) * targetCellArea + overhead * 40
        return max(minimum, min(460, area / width))
    }
}
