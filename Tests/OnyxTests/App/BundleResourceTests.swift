import XCTest
@testable import OnyxLib

/// `Bundle.module` must never be referenced from the executable target.
///
/// SPM generates it as a `static let` that **fatalErrors** when it can't
/// find its bundle, and it looks in exactly two places:
///
///   1. `Bundle.main.bundleURL/Onyx_Onyx.bundle` — the .app ROOT, which
///      is not a legal location for resources in a signed bundle (they
///      belong under Contents/), so a packaged app never has it there.
///   2. An ABSOLUTE path into the build directory of whichever machine
///      compiled the binary.
///
/// On the build machine, running from the repo, (2) always resolves — so
/// this cannot fail in development, cannot fail in CI on the build
/// machine, and fails instantly for every other user. The first packaged
/// DMG crashed in `OnyxApp.init()` before drawing a window, on exactly
/// this.
///
/// Resources for the app belong in Contents/Resources, reached through
/// `Bundle.main`. This test is the guard, because no runtime test on the
/// build machine can be.
final class BundleResourceTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/OnyxTests/App/this.swift
            .deletingLastPathComponent()          // App
            .deletingLastPathComponent()          // OnyxTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources")
    }

    func testNoBundleModuleInShippedSources() throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sourceRoot,
                                         includingPropertiesForKeys: nil) else {
            return XCTFail("couldn't walk \(sourceRoot.path)")
        }

        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                // Skip the comment that explains why this rule exists.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if line.contains("Bundle.module") {
                    let name = url.lastPathComponent
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            Bundle.module referenced in \(offenders.joined(separator: ", ")).
            It fatalErrors on any machine that didn't compile the binary —
            the build machine can't reproduce it. Put the resource in
            Contents/Resources (package.sh does) and read it via
            Bundle.main instead.
            """)
    }

    /// The packaging script must actually place resources where
    /// `Bundle.main` looks, or the rule above just moves the failure.
    func testPackageScriptPutsResourcesInContentsResources() throws {
        let script = try String(
            contentsOf: sourceRoot.deletingLastPathComponent()
                .appendingPathComponent("package.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("$APP_BUNDLE/Contents/Resources/"),
                      "resources must land under Contents/, where Bundle.main looks")
        XCTAssertTrue(script.contains("AppIcon.icns"),
                      "the icon is what OnyxApp.init loads at startup")
    }
}
