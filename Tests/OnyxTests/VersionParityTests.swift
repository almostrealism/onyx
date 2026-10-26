import XCTest
@testable import OnyxVersion

/// One version number for every Onyx (CLAUDE.md): the iOS app's comes from
/// Apps/OnyxToday/Version.xcconfig, which must say what OnyxVersion says.
final class VersionParityTests: XCTestCase {

    func testTheIOSAppHasTheSameVersion() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Apps/OnyxToday/Version.xcconfig")
        let text = try String(contentsOf: file, encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") }
        let version = line?.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(version, OnyxVersion.current,
                       "bump Apps/OnyxToday/Version.xcconfig with Sources/OnyxVersion/OnyxVersion.swift")
    }
}
