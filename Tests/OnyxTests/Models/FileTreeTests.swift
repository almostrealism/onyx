import XCTest
@testable import OnyxLib

/// The file browser's tree: folders open in place, their entries loaded
/// on first open, rows indented under them.
final class FileTreeTests: XCTestCase {

    private func dir(_ n: String) -> RemoteEntry { RemoteEntry(name: n, isDirectory: true, size: "", modified: "") }
    private func file(_ n: String) -> RemoteEntry { RemoteEntry(name: n, isDirectory: false, size: "1K", modified: "") }

    func testClosedFoldersShowOnlyTheRoots() {
        let rows = FileTree().rows(roots: [dir("src"), file("README.md")], in: "/repo")
        XCTAssertEqual(rows.map(\.path), ["/repo/src", "/repo/README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 0])
    }

    func testOpeningAFolderAsksForItsEntriesOnce() {
        var tree = FileTree()
        XCTAssertTrue(tree.toggle("/repo/src"), "first open: fetch")
        XCTAssertTrue(tree.loading.contains("/repo/src"))
        tree.loaded("/repo/src", [file("main.swift")])
        XCTAssertFalse(tree.toggle("/repo/src"), "close")
        XCTAssertFalse(tree.toggle("/repo/src"), "reopen: already loaded")
    }

    func testOpenFoldersNestTheirEntries() {
        var tree = FileTree()
        _ = tree.toggle("/repo/src")
        tree.loaded("/repo/src", [dir("ui"), file("main.swift")])
        _ = tree.toggle("/repo/src/ui")
        tree.loaded("/repo/src/ui", [file("view.swift")])

        let rows = tree.rows(roots: [dir("src"), file("README.md")], in: "/repo/")
        XCTAssertEqual(rows.map(\.path), ["/repo/src", "/repo/src/ui", "/repo/src/ui/view.swift",
                                          "/repo/src/main.swift", "/repo/README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(rows.first?.isExpanded, true)
    }

    func testAClosedParentHidesOpenChildren() {
        var tree = FileTree()
        _ = tree.toggle("/r/a"); tree.loaded("/r/a", [dir("b")])
        _ = tree.toggle("/r/a/b"); tree.loaded("/r/a/b", [file("c")])
        _ = tree.toggle("/r/a")   // close a
        XCTAssertEqual(tree.rows(roots: [dir("a")], in: "/r").map(\.path), ["/r/a"])
        _ = tree.toggle("/r/a")   // reopen: b is still open
        XCTAssertEqual(tree.rows(roots: [dir("a")], in: "/r").map(\.path), ["/r/a", "/r/a/b", "/r/a/b/c"])
    }

    func testAFailedFolderClosesSoTheNextClickRetries() {
        var tree = FileTree()
        _ = tree.toggle("/r/locked")
        tree.failed("/r/locked", "Permission denied")
        XCTAssertFalse(tree.expanded.contains("/r/locked"))
        XCTAssertEqual(tree.failures["/r/locked"], "Permission denied")
        XCTAssertTrue(tree.toggle("/r/locked"), "retry fetches")
        XCTAssertNil(tree.failures["/r/locked"])
    }
}
