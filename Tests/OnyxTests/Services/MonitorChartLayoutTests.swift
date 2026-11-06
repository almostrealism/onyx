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
                  for gpus in 0...(perHost > 1 ? 1 : 0) {
                    let available: CGFloat = 600
                    let h = MonitorChartLayout.fleetChartHeight(
                        available: available, rows: rows, chartsPerHost: perHost, gpuCharts: gpus,
                        rowSpacing: 10, innerSpacing: 3, fontScale: scale, minChartHeight: 22)
                    let gpuH = (h * MonitorChartLayout.gpuScale).rounded(.down)
                    let header = MonitorChartLayout.lineHeight(11, fontScale: scale)
                    let row = header + CGFloat(perHost) * (3 + title(scale))
                        + CGFloat(perHost - gpus) * h + CGFloat(gpus) * gpuH
                    let total = CGFloat(rows) * row + CGFloat(rows - 1) * 10
                    XCTAssertLessThanOrEqual(total, available,
                                             "scale \(scale), \(rows) rows × \(perHost) charts, \(gpus) GPU")
                  }
                }
            }
        }
    }

    func testSingleHostFitsItsBudget() {
        for scale: CGFloat in [1, 1.5] {
            let s = MonitorChartLayout.singleHost(available: 500, hasMemory: true, hasGPU: true,
                                                  fontScale: scale)
            XCTAssertLessThanOrEqual(s.cpu + s.memory + 2 * title(scale) + 8, 500)
            XCTAssertGreaterThan(s.cpu, s.memory, "CPU stays the big one")
            XCTAssertEqual(s.gpu, (s.memory * MonitorChartLayout.gpuScale).rounded(.down))

            // A GPU alone makes the row shorter, and CPU gets the room.
            let gpuOnly = MonitorChartLayout.singleHost(available: 500, hasMemory: false, hasGPU: true,
                                                        fontScale: scale)
            XCTAssertLessThanOrEqual(gpuOnly.cpu + gpuOnly.gpu + 2 * title(scale) + 8, 500)
            XCTAssertGreaterThan(gpuOnly.cpu, s.cpu)
            XCTAssertEqual(gpuOnly.memory, 0)

            let alone = MonitorChartLayout.singleHost(available: 500, hasMemory: false, hasGPU: false,
                                                      fontScale: scale)
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
            let total = label + 10 + 2 * (title(scale) + 10) + m.cpu + m.gpu + mem + 10
            XCTAssertLessThanOrEqual(total, available, "scale \(scale)")
            XCTAssertEqual(m.gpu, (m.cpu * MonitorChartLayout.gpuScale).rounded(.down))
        }
    }

    // MARK: GPU

    /// The GPU is half the chart it was: off, drawing, or maxed is all it
    /// usually has to say.
    func testGPUIsHalfInTheDetailedColumn() {
        let both = MonitorChartLayout.detailedSubCharts(hasMemory: true, hasGPU: true)
        XCTAssertEqual(both.gpu, 21, "half of the 42 it had beside memory")
        XCTAssertEqual(both.memory + both.gpu, 84, "memory keeps the rest")
        XCTAssertEqual(MonitorChartLayout.detailedSubCharts(hasMemory: false, hasGPU: true).gpu, 50)
        XCTAssertEqual(MonitorChartLayout.detailedSubCharts(hasMemory: true, hasGPU: false).memory, 100)
    }

    func testGPUGridKeepsCellsTheSizeOfTheOthers() {
        XCTAssertEqual(CGFloat(MonitorChartLayout.gpuRows) / 20, MonitorChartLayout.gpuScale)
    }

    // MARK: Strip

    func testTitledTimingTilesGetATallerStrip() {
        let plain = SimpleMonitorBody.bottomStripHeight(titledTimingTiles: false, fontScale: 1)
        let titled = SimpleMonitorBody.bottomStripHeight(titledTimingTiles: true, fontScale: 1)
        XCTAssertGreaterThan(titled, plain)
    }
}
