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

    // MARK: - Publishing

    /// Releasing 0.17 offered to upload dist/Onyx-0.16.dmg under the new
    /// name, defaulting to yes: `ls -t dist/*.dmg` finds the PREVIOUS
    /// release. Nothing downstream could catch it — the name, the URL and
    /// the checksum would all be consistent with a 0.17 release that
    /// contained the 0.16 app.
    func testReleaseNeverOffersAnArbitraryDiskImage() throws {
        let text = try code("release.sh")
        XCTAssertFalse(text.contains("ls -t \"$DIST_DIR\"/*.dmg"),
                       "the newest image in dist/ is the last RELEASE, not this one")
    }

    /// The file name is chosen by whoever built it and proves nothing, so
    /// the image is opened and the app's own version read before anything
    /// is published.
    func testReleaseChecksTheVersionInsideTheImage() throws {
        let text = try code("release.sh")
        XCTAssertTrue(text.contains("hdiutil attach"),
                      "release.sh must mount the image to check it")
        XCTAssertTrue(text.contains("Print :CFBundleShortVersionString"),
                      "…and read the app's own version out of it")
        XCTAssertTrue(text.contains("$INSIDE\" != \"$VERSION"),
                      "…and refuse when it disagrees with the release")
    }
}

/// What gets signed, and what counts as notarized.
///
/// The first bundle to carry the MCP bridge was rejected by Apple as
/// "Invalid" with no reason shown, and the visible error was a stapler
/// failure ("Record not found") several steps later. Two causes, both
/// locked here.
final class PackagingSignatureTests: XCTestCase {

    private var packageScript: String {
        (try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("package.sh"), encoding: .utf8)) ?? ""
    }

    /// The bridge in Contents/Resources is a Mach-O executable, and
    /// notarization checks every executable in the bundle. Signing the
    /// app alone leaves it as the linker made it: ad-hoc, no identity,
    /// no hardened runtime.
    func testTheNestedMacBridgeIsSigned() {
        let text = packageScript
        XCTAssertTrue(text.contains("$MCP_DIR\"/OnyxMCP-macos-*"),
                      "the macOS bridge inside the bundle must be signed too")
        guard let nested = text.range(of: "OnyxMCP-macos-*"),
              let app = text.range(of: "--sign \"$IDENTITY\" \"$APP_BUNDLE\"") else {
            return XCTFail("couldn't find both signing steps")
        }
        XCTAssertTrue(nested.lowerBound < app.lowerBound,
                      "nested code signs first — the bundle's signature seals it")
    }

    /// "Is it signed" answers yes for a linker ad-hoc signature, which
    /// is what was there. The check has to be for a real identity.
    func testThePreflightLooksForADeveloperIDNotJustASignature() {
        XCTAssertTrue(packageScript.contains("Authority=Developer ID Application"),
                      "an ad-hoc signature passes codesign --verify and fails notarization")
    }

    /// `notarytool submit --wait` exits 0 for a REJECTED submission —
    /// it succeeded at submitting and waiting. Trusting that sent a
    /// rejected DMG on to stapler, which is where the user finally saw
    /// an error, and it named a CloudKit record rather than a cause.
    func testTheNotarizationVerdictIsReadFromTheOutputNotTheExitStatus() {
        let text = packageScript
        XCTAssertTrue(text.contains("\"$SUB_STATUS\" = \"Accepted\""),
                      "only Accepted may staple")
        XCTAssertTrue(text.contains("notarytool log"),
                      "a rejection must fetch the log that names the files")
    }
}
