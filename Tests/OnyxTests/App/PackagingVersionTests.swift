import XCTest
@testable import OnyxLib

/// What the shipped bundle says its version is.
///
/// The build identifier used to come from `git describe`, which names the
/// most recent TAG — so on the way to a release, before the new tag
/// exists, every build announced itself as the PREVIOUS version
/// ("Onyx 0.16-65-g42764a1") while the bundle inside it was 0.17, and a
/// locally installed build's About panel read "Version 0.17 (0.16-65-…)".
/// A number that is only right once someone remembers to tag is the same
/// mistake as a version constant kept in two files, which is what
/// OnyxVersion exists to prevent.
final class PackagingVersionTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private func script(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// The script with its comments removed — a comment is allowed to
    /// SAY "git describe" while explaining why it isn't used.
    private func code(_ name: String) throws -> String {
        try script(name)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// Both scripts read the one constant rather than carrying a copy.
    func testTheScriptsReadTheVersionConstant() throws {
        for name in ["package.sh", "install.sh"] {
            let text = try script(name)
            XCTAssertTrue(text.contains("Sources/OnyxVersion/OnyxVersion.swift"),
                          "\(name) must read the shared constant")
        }
    }

    /// Nothing a user sees may be derived from the last tag.
    func testNoScriptDerivesAVersionFromGitDescribe() throws {
        for name in ["package.sh", "install.sh"] {
            let text = try code(name)
            XCTAssertFalse(text.contains("git describe"),
                           "\(name) uses git describe, which names the PREVIOUS tag "
                           + "until the release is tagged")
        }
    }

    /// The marketing version is the constant; the build number is a count,
    /// which is monotonic and can't be mistaken for a release.
    func testThePlistIsStampedFromTheConstantAndACount() throws {
        for name in ["package.sh", "install.sh"] {
            let text = try script(name)
            XCTAssertTrue(text.contains("Set :CFBundleShortVersionString $VERSION"),
                          "\(name) must stamp the short version from the constant")
            XCTAssertTrue(text.contains("Set :CFBundleVersion $BUILD_NUMBER"),
                          "\(name) must stamp a build number, not a version string")
            XCTAssertTrue(text.contains("git rev-list --count HEAD"),
                          "\(name) must derive the build number from the commit count")
        }
    }

    /// The DMG's name is what the website links to, so it is the release
    /// version and nothing else.
    func testTheDMGIsNamedForTheRelease() throws {
        XCTAssertTrue(try script("package.sh").contains("${APP_NAME}-${VERSION}.dmg"))
    }
}
