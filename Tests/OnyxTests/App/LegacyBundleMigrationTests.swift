import XCTest
@testable import OnyxLib

/// Upgrading from `com.onyx.terminal` to `ai.almostrealism.onyx` keeps a
/// user's settings, windows and browser data.
final class LegacyBundleMigrationTests: XCTestCase {

    private var library: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        library = fm.temporaryDirectory.appendingPathComponent("onyx-lib-\(UUID().uuidString)")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        suite = "onyx-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? fm.removeItem(at: library)
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ path: String, directory: Bool, contents: String = "x") throws {
        let url = library.appendingPathComponent(path)
        if directory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try contents.write(to: url.appendingPathComponent("data"), atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func testSettingsAndLibraryItemsComeAcross() throws {
        try make("WebKit/com.onyx.terminal", directory: true)
        try make("HTTPStorages/com.onyx.terminal.binarycookies", directory: false)
        try make("Saved Application State/com.onyx.terminal.savedState", directory: true)
        let result = LegacyBundleMigration.migrate(
            legacyDefaults: ["windowFrame_full_0": [1.0, 2.0, 3.0, 4.0], "pr_workflows_included": ["CI"]],
            into: defaults, library: library)
        XCTAssertEqual(result.copiedDefaults, 2)
        XCTAssertEqual(defaults.stringArray(forKey: "pr_workflows_included"), ["CI"])
        XCTAssertEqual(Set(result.copiedItems), [
            "WebKit/ai.almostrealism.onyx",
            "HTTPStorages/ai.almostrealism.onyx.binarycookies",
            "Saved Application State/ai.almostrealism.onyx.savedState"])
        XCTAssertTrue(fm.fileExists(atPath: library.appendingPathComponent("WebKit/ai.almostrealism.onyx/data").path))
        XCTAssertTrue(fm.fileExists(atPath: library.appendingPathComponent("WebKit/com.onyx.terminal").path),
                      "copied, not moved: an older Onyx still finds its own")
    }

    /// Nothing the new app already has is overwritten.
    func testWhatTheNewAppHasIsKept() throws {
        defaults.set("new", forKey: "k")
        try make("WebKit/com.onyx.terminal", directory: true, contents: "old")
        try make("WebKit/ai.almostrealism.onyx", directory: true, contents: "new")
        let result = LegacyBundleMigration.migrate(legacyDefaults: ["k": "old"], into: defaults, library: library)
        XCTAssertEqual(defaults.string(forKey: "k"), "new")
        XCTAssertEqual(result.copiedDefaults, 0)
        XCTAssertTrue(result.copiedItems.isEmpty)
        let data = try String(contentsOf: library.appendingPathComponent("WebKit/ai.almostrealism.onyx/data"), encoding: .utf8)
        XCTAssertEqual(data, "new")
    }

    func testItRunsOnce() {
        LegacyBundleMigration.migrate(legacyDefaults: ["a": 1], into: defaults, library: library)
        defaults.removeObject(forKey: "a")
        let again = LegacyBundleMigration.migrate(legacyDefaults: ["a": 1], into: defaults, library: library)
        XCTAssertTrue(again.skipped)
        XCTAssertNil(defaults.object(forKey: "a"))
    }

    /// A new user has nothing to bring, and that's fine.
    func testANewUserHasNothingToMigrate() {
        let result = LegacyBundleMigration.migrate(legacyDefaults: nil, into: defaults, library: library)
        XCTAssertEqual(result, LegacyBundleMigration.Result())
    }

    /// The app and the migration must agree on the id it migrates TO.
    func testTheInfoPlistCarriesTheNewID() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OnyxApp/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist))
        XCTAssertEqual(dict["CFBundleIdentifier"] as? String, LegacyBundleMigration.currentID)
    }
}
