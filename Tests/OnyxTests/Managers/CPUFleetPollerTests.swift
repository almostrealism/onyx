import XCTest
@testable import OnyxLib

final class CPUFleetPollerTests: XCTestCase {

    func testColor_isDeterministicPerHostID() {
        // Same host UUID must always produce the same hex color, so a host
        // never changes tint between app launches.
        let h = HostConfig(id: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
                           label: "alpha", ssh: SSHConfig(host: "a.example"))
        let c1 = CPUFleetPoller.color(for: h)
        let c2 = CPUFleetPoller.color(for: h)
        XCTAssertEqual(c1, c2)
    }

    func testColor_returnsValidHexString() {
        // Sample a handful of UUIDs; every output must be a "#RRGGBB" string
        // that the screensaver's NSColor.fromOnyxHex parser will accept.
        let hexPattern = #/^#[0-9A-Fa-f]{6}$/#
        for _ in 0..<32 {
            let h = HostConfig(id: UUID(),
                               label: "x", ssh: SSHConfig(host: "x"))
            let c = CPUFleetPoller.color(for: h)
            XCTAssertNotNil(try? hexPattern.wholeMatch(in: c),
                            "expected #RRGGBB, got: \(c)")
        }
    }

    func testColor_localhostMapsToFirstPaletteEntry() {
        // Localhost's UUID is all zeros — the deterministic hash should put
        // it on the first palette slot (amber). Tested explicitly so the
        // visual identity of "this is your local machine" stays stable.
        let h = HostConfig.localhost
        XCTAssertEqual(CPUFleetPoller.color(for: h), "#FF8C42")
    }

    // MARK: - container activity filter

    /// Containers that have never crossed the 1% threshold should be
    /// excluded immediately — same as DockerStatsManager's behavior in
    /// the in-app monitor.
    func test_filterByActivity_excludesNeverActiveContainers() {
        let poller = CPUFleetPoller.shared
        poller.resetActivityForTesting()
        let result = poller.filterByActivity(
            [ContainerStream(name: "sidecar", cpu: 0.2),
             ContainerStream(name: "cron",    cpu: 0.0)],
            hostID: "host-1"
        )
        XCTAssertTrue(result.isEmpty,
                      "Containers that haven't crossed 1% should be excluded; got \(result.map(\.name))")
    }

    /// Containers above 1% are always included; once seen, they stay
    /// included briefly even if their CPU dips back below the threshold.
    func test_filterByActivity_keepsRecentlyActiveContainers() {
        let poller = CPUFleetPoller.shared
        poller.resetActivityForTesting()

        // First pass: container is busy, should appear.
        let pass1 = poller.filterByActivity(
            [ContainerStream(name: "web", cpu: 5.0)],
            hostID: "host-1"
        )
        XCTAssertEqual(pass1.map(\.name), ["web"])

        // Second pass moments later: container went quiet but should
        // still be in the list (activity window hasn't elapsed).
        let pass2 = poller.filterByActivity(
            [ContainerStream(name: "web", cpu: 0.05)],
            hostID: "host-1"
        )
        XCTAssertEqual(pass2.map(\.name), ["web"],
                       "container should remain visible while inside the activity window")
    }

    func test_filterByActivity_hostsAreIndependent() {
        // Two hosts running the same container name shouldn't pollute
        // each other's activity record.
        let poller = CPUFleetPoller.shared
        poller.resetActivityForTesting()
        _ = poller.filterByActivity(
            [ContainerStream(name: "redis", cpu: 7.5)], hostID: "host-A"
        )
        let other = poller.filterByActivity(
            [ContainerStream(name: "redis", cpu: 0.0)], hostID: "host-B"
        )
        XCTAssertTrue(other.isEmpty,
                      "host B's redis has never been active — must not inherit host A's activity")
    }
}
