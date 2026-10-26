import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// The at-a-glance layouts' charts must fit the area above the bottom
/// strip — titles and spacing included — or they're drawn behind the
/// strip's text. These add up what each layout actually stacks.
final class MonitorChartLayoutTests: XCTestCase {

    private func title(_ s: CGFloat) -> CGFloat { MonitorChartLayout.chartTitleHeight(fontScale: s) }

    // MARK: Grid

    func testUpToThreeHostsIsOneColumn() {
        for n in 1...3 {
            let g = MonitorChartLayout.fleetGrid(hosts: n, maxRows: 3)
            XCTAssertEqual(g.columns, 1)
            XCTAssertEqual(g.rows, n)
        }
    }

    func testFourOrMoreHostsGoSideBySide() {
        XCTAssertEqual(MonitorChartLayout.fleetGrid(hosts: 4, maxRows: 3).columns, 2)
        XCTAssertEqual(MonitorChartLayout.fleetGrid(hosts: 4, maxRows: 3).rows, 2)
        XCTAssertEqual(MonitorChartLayout.fleetGrid(hosts: 5, maxRows: 3).rows, 3)
        XCTAssertEqual(MonitorChartLayout.fleetGrid(hosts: 6, maxRows: 3).columns, 2)
        // Never more than three rows, however big the fleet.
        for n in 1...20 {
            XCTAssertLessThanOrEqual(MonitorChartLayout.fleetGrid(hosts: n, maxRows: 3).rows, 3)
        }
    }

    func testColumnsKeepOrderAndFillEvenly() {
        let cols = MonitorChartLayout.columnsOf([1, 2, 3, 4, 5], columns: 2)
        XCTAssertEqual(cols, [[1, 2, 3], [4, 5]])
        XCTAssertEqual(MonitorChartLayout.columnsOf([1, 2, 3, 4], columns: 2), [[1, 2], [3, 4]])
        XCTAssertEqual(MonitorChartLayout.columnsOf([Int](), columns: 2), [])
    }

    // MARK: Fit

    func testStackedFleetFitsItsBudget() {
        for scale: CGFloat in [1, 1.25, 1.5] {
            for rows in 1...3 {
                for perHost in 1...3 {
                    let available: CGFloat = 600
                    let h = MonitorChartLayout.fleetChartHeight(
                        available: available, rows: rows, chartsPerHost: perHost,
                        rowSpacing: 10, innerSpacing: 3, fontScale: scale, minChartHeight: 22)
                    let header = MonitorChartLayout.lineHeight(11, fontScale: scale)
                    let row = header + CGFloat(perHost) * (3 + title(scale) + h)
                    let total = CGFloat(rows) * row + CGFloat(rows - 1) * 10
                    XCTAssertLessThanOrEqual(total, available,
                                             "scale \(scale), \(rows) rows × \(perHost) charts")
                }
            }
        }
    }

    func testSingleHostFitsItsBudget() {
        for scale: CGFloat in [1, 1.5] {
            let s = MonitorChartLayout.singleHost(available: 500, hasSubRow: true, fontScale: scale)
            XCTAssertLessThanOrEqual(s.cpu + s.sub + 2 * title(scale) + 8, 500)
            XCTAssertGreaterThan(s.cpu, s.sub, "CPU stays the big one")

            let alone = MonitorChartLayout.singleHost(available: 500, hasSubRow: false, fontScale: scale)
            XCTAssertLessThanOrEqual(alone.cpu + title(scale), 500)
        }
    }

    func testMergedFleetFitsItsBudget() {
        for scale: CGFloat in [1, 1.5] {
            let available: CGFloat = 520
            let m = MonitorChartLayout.fleetMerged(available: available, hasGPU: true,
                                                   hasMemory: true, fontScale: scale)
            let label = MonitorChartLayout.lineHeight(9, fontScale: scale)
            let mem = label + 2 + title(scale) + m.memory
            let total = label + 10 + 2 * (title(scale) + m.chart + 10) + mem + 10
            XCTAssertLessThanOrEqual(total, available, "scale \(scale)")
        }
    }

    // MARK: Strip

    func testTitledTimingTilesGetATallerStrip() {
        let plain = SimpleMonitorBody.bottomStripHeight(titledTimingTiles: false, fontScale: 1)
        let titled = SimpleMonitorBody.bottomStripHeight(titledTimingTiles: true, fontScale: 1)
        XCTAssertGreaterThan(titled, plain)
    }
}
