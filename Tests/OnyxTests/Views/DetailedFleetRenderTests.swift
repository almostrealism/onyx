import XCTest
import SwiftUI
import AppKit
@testable import OnyxCore
@testable import OnyxLib

/// The detailed overlay's right column with a six-host fleet: three rows
/// of host stacks in two columns, not six in one. Set
/// ONYX_FLEET_RENDER_DIR to look at it.
@MainActor
final class DetailedFleetRenderTests: XCTestCase {

    override func tearDown() {
        CPUStreamStore.shared.reset()
        super.tearDown()
    }

    func testSixHostsAreAThreeByTwoGrid() throws {
        let state = AppState()
        let names = ["workstation", "build-02", "gpu-01", "gpu-02", "ci-runner", "db-01"]
        let hosts = names.enumerated().map { i, name in
            HostConfig(label: name, ssh: SSHConfig(host: "\(name).lan", user: "me", tmuxSession: "main"))
        }
        state.hosts = hosts
        CPUStreamStore.shared.reset()
        let now = Date().timeIntervalSince1970
        for (h, host) in hosts.enumerated() {
            for i in 0..<120 {
                let t = now - Double(120 - i) * 10
                let wave = (sin(Double(i + h * 17) / 7) + 1) / 2
                CPUStreamStore.shared.appendSample(
                    hostID: host.id.uuidString, label: host.label, color: "#66CCFF",
                    cpu: 10 + wave * Double(30 + h * 10),
                    gpu: h % 3 == 1 ? nil : 20 + wave * 60,
                    mem: 8 + wave * 4, memTotal: 64, timestamp: t)
            }
        }
        let series = FleetSeries.build(streams: CPUStreamStore.shared.snapshot(), hosts: hosts)
        XCTAssertEqual(series.count, 6)
        let grid = MonitorChartLayout.fleetGrid(hosts: series.count, maxRows: MonitorChartLayout.fleetMaxRows)
        XCTAssertEqual(grid.columns, 2)
        XCTAssertEqual(grid.rows, 3)

        // The right column of a 1512pt-wide overlay: 35%, less its padding.
        let monitor = MonitorManager(appState: state)
        let view = FleetStackedCharts(appState: state, monitor: monitor,
                                      accentColor: Color(red: 0.4, green: 0.8, blue: 1),
                                      availableHeight: MonitorView.detailedFleetHeight,
                                      minChartHeight: 14,
                                      maxRows: MonitorChartLayout.fleetMaxRows,
                                      clipsToHeight: false, columnSpacing: 14)
            .padding(16)
            .frame(width: 500)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        // Three rows of hosts fit the budget, give or take the floor.
        XCTAssertLessThan(image.size.height, MonitorView.detailedFleetHeight + 32 + 40)
        if let dir = ProcessInfo.processInfo.environment["ONYX_FLEET_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("detailed-fleet.png"))
        }
    }
}
