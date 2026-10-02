import XCTest
@testable import OnyxLib

/// Settings is a sidebar of categories now. Moving every section into a
/// pane must not lose one: a section defined but placed nowhere is a
/// setting nobody can reach.
final class SettingsPaneTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEverySettingsSectionIsPlacedInAPane() throws {
        let sections = try source("Sources/OnyxLib/Views/SettingsSections.swift")
        let view = try source("Sources/OnyxLib/Views/SettingsView.swift")
        let names = sections.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("struct "), line.contains("SettingsSection") else { return nil }
            return line.dropFirst("struct ".count).split(separator: ":").first.map(String.init)
        }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            XCTAssertTrue(view.contains("\(name)("), "\(name) isn't placed in any Settings pane")
        }
    }

    /// The headers other screens send people to ("Settings → KEYBOARD")
    /// still exist inside some pane.
    func testHeadersReferencedElsewhereStillExist() throws {
        let view = try source("Sources/OnyxLib/Views/SettingsView.swift")
        for header in ["\"HOSTS\"", "\"KEYBOARD\"", "\"MONITOR\""] {
            XCTAssertTrue(view.contains(header), "\(header) is referenced as Settings → … elsewhere")
        }
    }

    func testPanesHaveDistinctTitles() {
        let titles = SettingsPane.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }
}
