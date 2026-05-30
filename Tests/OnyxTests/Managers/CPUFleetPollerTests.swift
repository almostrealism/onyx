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
}
