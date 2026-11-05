import XCTest
@testable import OnyxVersion

/// One version number for every Onyx (CLAUDE.md): the iOS app's comes from
/// Apps/OnyxToday/Version.xcconfig and the widget's from
/// Apps/OnyxWidget/Version.xcconfig, which must say what OnyxVersion says.
final class VersionParityTests: XCTestCase {

    private func marketingVersion(_ path: String) throws -> String? {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent(path)
        let text = try String(contentsOf: file, encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.hasPrefix("MARKETING_VERSION") }
        return line?.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
    }

    func testTheIOSAppHasTheSameVersion() throws {
        XCTAssertEqual(try marketingVersion("Apps/OnyxToday/Version.xcconfig"), OnyxVersion.current,
                       "bump Apps/OnyxToday/Version.xcconfig with Sources/OnyxVersion/OnyxVersion.swift")
    }

    /// package.sh stamps the real version on the widget anyway; this keeps
    /// a build from Xcode honest too.
    func testTheWidgetHasTheSameVersion() throws {
        XCTAssertEqual(try marketingVersion("Apps/OnyxWidget/Version.xcconfig"), OnyxVersion.current,
                       "bump Apps/OnyxWidget/Version.xcconfig with Sources/OnyxVersion/OnyxVersion.swift")
    }
}
