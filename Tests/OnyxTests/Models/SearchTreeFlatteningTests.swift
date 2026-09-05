import XCTest
@testable import OnyxLib

/// Flattening the search-results tree before it reaches the lazy stack.
///
/// The recursive version of this view hung the app for 30 seconds on a
/// large result set: a LazyVStack is only lazy about its direct
/// children, so nesting a ForEach per level forced SwiftUI to walk and
/// place every node on every layout pass. These lock the flattening that
/// replaced it.
final class SearchTreeFlatteningTests: XCTestCase {

    private func dir(_ name: String, _ children: [SearchTreeNode] = []) -> SearchTreeNode {
        let n = SearchTreeNode(name: name, fullPath: "/\(name)", isDirectory: true)
        n.children = children
        return n
    }

    private func file(_ name: String) -> SearchTreeNode {
        SearchTreeNode(name: name, fullPath: "/\(name)", isDirectory: false)
    }

    // MARK: - Order and depth

    /// Depth-first, parents before their children — the order you'd get
    /// from the recursive version, since it has to look identical.
    func testRowsComeOutInReadingOrder() {
        let tree = [dir("src", [file("a.swift"), dir("sub", [file("b.swift")])]),
                    file("README.md")]
        let rows = SearchTreeNode.visibleRows(roots: tree, collapsed: [])

        XCTAssertEqual(rows.map(\.node.name), ["src", "a.swift", "sub", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 0])
    }

    func testEverythingIsExpandedByDefault() {
        // Matches the old node default of isExpanded = true.
        let rows = SearchTreeNode.visibleRows(
            roots: [dir("a", [dir("b", [file("c")])])], collapsed: [])
        XCTAssertEqual(rows.count, 3)
    }

    // MARK: - Collapsing

    func testCollapsingHidesTheWholeSubtreeNotJustOneLevel() {
        let deep = dir("sub", [file("b.swift")])
        let src = dir("src", [file("a.swift"), deep])
        let rows = SearchTreeNode.visibleRows(roots: [src], collapsed: [src.id])

        XCTAssertEqual(rows.map(\.node.name), ["src"],
                       "a collapsed directory must not leave its grandchildren on screen")
    }

    func testCollapsingOneBranchLeavesItsSiblingsAlone() {
        let a = dir("a", [file("a1")])
        let b = dir("b", [file("b1")])
        let rows = SearchTreeNode.visibleRows(roots: [a, b], collapsed: [a.id])
        XCTAssertEqual(rows.map(\.node.name), ["a", "b", "b1"])
    }

    /// A file id in the collapsed set must not swallow anything — only
    /// directories have children to hide.
    func testCollapsingAFileIsHarmless() {
        let f = file("a.swift")
        let rows = SearchTreeNode.visibleRows(roots: [dir("src", [f])], collapsed: [f.id])
        XCTAssertEqual(rows.map(\.node.name), ["src", "a.swift"])
    }

    // MARK: - Shapes that used to hurt

    func testAnEmptyTreeProducesNoRows() {
        XCTAssertTrue(SearchTreeNode.visibleRows(roots: [], collapsed: []).isEmpty)
    }

    /// Deep trees are the case that caused the hang, so the replacement
    /// must not itself fail on depth — hence an explicit stack rather
    /// than recursion, which would trade a slow render for a crash.
    func testAVeryDeepTreeDoesNotExhaustTheStack() {
        let depth = 5_000
        var leaf = dir("d0")
        let root = leaf
        for i in 1..<depth {
            let child = dir("d\(i)")
            leaf.children = [child]
            leaf = child
        }

        let rows = SearchTreeNode.visibleRows(roots: [root], collapsed: [])
        XCTAssertEqual(rows.count, depth)
        XCTAssertEqual(rows.last?.depth, depth - 1)
    }

    /// The wide case: a search across a big repo. This is only asserting
    /// that flattening is linear and quick — the layout cost it exists to
    /// avoid isn't measurable from here.
    func testAWideTreeFlattensQuickly() {
        let files = (0..<5_000).map { file("f\($0).swift") }
        let root = dir("repo", files)

        let started = Date()
        let rows = SearchTreeNode.visibleRows(roots: [root], collapsed: [])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(rows.count, 5_001)
        XCTAssertLessThan(elapsed, 0.5, "flattening should be trivially fast next to layout")
    }
}
