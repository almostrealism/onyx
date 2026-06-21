import XCTest
@testable import OnyxLib

final class FilePathDetectorTests: XCTestCase {

    // MARK: - isFilePath (the Rule A / Rule B decision)

    func test_threeSlashes_isPath() {
        XCTAssertTrue(FilePathDetector.isFilePath("/usr/local/bin", favorites: []))
        XCTAssertTrue(FilePathDetector.isFilePath("/a/b/c", favorites: []))
    }

    func test_twoSlashes_withoutFavorite_isNotPath() {
        XCTAssertFalse(FilePathDetector.isFilePath("/usr/bin", favorites: []))
        XCTAssertFalse(FilePathDetector.isFilePath("/root/file", favorites: []))
    }

    func test_favoritePrefix_makesShortPathRecognized() {
        XCTAssertTrue(FilePathDetector.isFilePath("/root/file", favorites: ["/root"]))
        XCTAssertTrue(FilePathDetector.isFilePath("/root", favorites: ["/root"]))
    }

    func test_favoriteBoundary_isComponentAware() {
        // "/root" favorite must not make "/rootbeer" a path.
        XCTAssertFalse(FilePathDetector.isFilePath("/rootbeer", favorites: ["/root"]))
    }

    func test_rootFavorite_isIgnored() {
        // A favorite of "/" would otherwise match everything — excluded.
        XCTAssertFalse(FilePathDetector.isFilePath("/etc", favorites: ["/"]))
        XCTAssertFalse(FilePathDetector.isFilePath("/a/b", favorites: ["/"]))
    }

    func test_favoriteWithTrailingSlash_tolerated() {
        XCTAssertTrue(FilePathDetector.isFilePath("/srv/app", favorites: ["/srv/"]))
    }

    // MARK: - matchRanges (extraction + validation in real text)

    private func paths(in text: String, favorites: [String] = []) -> [String] {
        let ns = text as NSString
        return FilePathDetector.matchRanges(in: text, favorites: favorites)
            .map { ns.substring(with: $0) }
    }

    func test_extracts_threeSlashPath_fromSentence() {
        XCTAssertEqual(paths(in: "see /usr/local/bin/tool for details"),
                       ["/usr/local/bin/tool"])
    }

    func test_ignores_shortPath_withoutFavorite() {
        XCTAssertEqual(paths(in: "cd /usr/bin now"), [])
    }

    func test_extracts_favoriteShortPath() {
        XCTAssertEqual(paths(in: "edit /root/notes.txt", favorites: ["/root"]),
                       ["/root/notes.txt"])
    }

    func test_ignores_fractionsAndDates() {
        // "/4" and "/06/17" are too short and aren't favorites.
        XCTAssertEqual(paths(in: "ratio 3/4 on 2024/06/17"), [])
    }

    func test_doesNotMatch_relativePaths() {
        // No leading slash → not an absolute path.
        XCTAssertEqual(paths(in: "src/main/app.swift here"), [])
    }

    func test_doesNotMisLink_innerSlashOfRelativePath() {
        // alpha/beta/gamma/delta/sigma/x/y must NOT yield /beta/gamma/...
        // (its first inner slash). It's relative; we don't know the root.
        XCTAssertEqual(paths(in: "alpha/beta/gamma/delta/sigma/x/y"), [])
    }

    func test_doesNotMisLink_homePath() {
        // ~/foo/bar/baz is home-relative; must not link /foo/bar/baz.
        XCTAssertEqual(paths(in: "~/foo/bar/baz/qux"), [])
    }

    func test_stillMatches_absolutePathAfterPunctuation() {
        // A slash at a real boundary (after '(' or '=') is still a path.
        XCTAssertEqual(paths(in: "see (/usr/local/bin/tool)"), ["/usr/local/bin/tool"])
        XCTAssertEqual(paths(in: "PATH=/opt/app/bin/run"), ["/opt/app/bin/run"])
    }

    func test_dotsAndDashesAllowedInSegments() {
        XCTAssertEqual(paths(in: "/var/log/my-app.2024/out.log"),
                       ["/var/log/my-app.2024/out.log"])
    }

    // MARK: - linkURL round-trip

    func test_linkURL_roundTripsPath() {
        let url = FilePathDetector.linkURL(for: "/root/my-file.txt")
        XCTAssertEqual(url?.scheme, "onyxfile")
        XCTAssertEqual(url?.path, "/root/my-file.txt")
    }
}
