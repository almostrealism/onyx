import SwiftUI

/// Reports a measured width up the view tree (used to pick a grid column
/// count from the available panel width).
struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Column layout for the favorites / notes grids: as many `.flexible` columns
/// as fit at `minCellWidth`, but never more than `maxColumns`. So on a wide
/// panel you get more ROWS instead of ever-narrower cells whose titles
/// truncate. `width == 0` (first render, before measurement) yields one
/// column, corrected on the next pass.
func cappedGridColumns(width: CGFloat,
                       minCellWidth: CGFloat = 130,
                       spacing: CGFloat = 6,
                       maxColumns: Int = 4) -> [GridItem] {
    let fit = max(1, Int((max(0, width) + spacing) / (minCellWidth + spacing)))
    let count = min(maxColumns, fit)
    return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
}
