import XCTest
import CoreGraphics
@testable import OnyxLib

/// The layout's whole purpose is that every box can be READ. These tests
/// pin the constraint (nobody below their minimum readable width), the
/// optimality of the row breaking, and the structural guarantees the
/// renderer depends on.
final class FavoriteLayoutTests: XCTestCase {

    private let panel = CGRect(x: 0, y: 0, width: 420, height: 260)

    private func tree(_ paths: [String]) -> [FavoriteTreeNode] {
        FavoriteTree.build(paths: paths)
    }

    /// Every box is at least as wide as its label needs (or, for a long
    /// name, the cap where middle-truncation takes over).
    private func assertAllLegible(_ boxes: [PlacedFavorite],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for box in boxes {
            let needed = min(
                FavoriteTreemapLayout.charWidth * CGFloat(box.label.count)
                    + FavoriteTreemapLayout.labelChrome,
                FavoriteTreemapLayout.maxLabelWidth)
            XCTAssertGreaterThanOrEqual(box.rect.width + 0.5, needed,
                                        "\(box.label) got \(box.rect.width)pt, needs \(needed)pt",
                                        file: file, line: line)
        }
    }

    // MARK: The failure this replaced

    /// The screenshot case: six long-named siblings in one container.
    /// Squarified put them side by side at ~110pt each ("c…n", "s…A").
    /// They must now break across rows instead.
    func testManyLongNamedSiblingsWrapInsteadOfShrinking() {
        let t = tree([
            "/w/AlmostRealism/common",
            "/w/AlmostRealism/rings-prod",
            "/w/AlmostRealism/sandboxA",
            "/w/AlmostRealism/sandboxB",
            "/w/AlmostRealism/sandboxC",
            "/w/AlmostRealism/staging",
        ])
        let height = FavoriteTreemapLayout.preferredHeight(for: t, width: panel.width)
        let boxes = FavoriteTreemapLayout.place(
            t, in: CGRect(x: 0, y: 0, width: panel.width, height: height))
        assertAllLegible(boxes)
        let rowTops = Set(boxes.map { Int($0.rect.minY) })
        XCTAssertGreaterThan(rowTops.count, 1, "six long names cannot fit on one row at 420pt")
        XCTAssertEqual(boxes.count, 6)
    }

    /// The other half: when there IS room, items still share a row —
    /// wrapping everything would waste the space we're trying to use.
    func testShortNamesShareARowWhenTheyFit() {
        let t = tree(["/a", "/b", "/c"])
        let boxes = FavoriteTreemapLayout.place(t, in: panel)
        XCTAssertEqual(Set(boxes.map { Int($0.rect.minY) }).count, 1,
                       "three short names fit across 420pt")
        assertAllLegible(boxes)
    }

    /// A very narrow panel degrades to a vertical list rather than a row
    /// of unreadable stubs.
    func testNarrowPanelStacksVertically() {
        let t = tree(["/projects/alpha-service", "/projects/beta-service",
                      "/projects/gamma-service"])
        let narrow = CGRect(x: 0, y: 0, width: 150, height: 400)
        let boxes = FavoriteTreemapLayout.place(t, in: narrow)
        XCTAssertEqual(Set(boxes.map { Int($0.rect.minY) }).count, boxes.count,
                       "each box on its own row")
        assertAllLegible(boxes)
    }

    // MARK: Constraint & invariants

    func testNestedBoxesAreAlsoLegible() {
        // The recursive minWidth is what guarantees this: a container is
        // never given a width that dooms its children.
        let t = tree([
            "/srv/deployments", "/srv/deployments/production-cluster",
            "/srv/deployments/staging-cluster", "/home/user/documents",
        ])
        let height = FavoriteTreemapLayout.preferredHeight(for: t, width: panel.width)
        let boxes = FavoriteTreemapLayout.place(
            t, in: CGRect(x: 0, y: 0, width: panel.width, height: height))
        assertAllLegible(boxes)
    }

    func testChildrenStayInsideTheirParent() {
        let t = tree(["/Users/a", "/Users/a/one", "/Users/a/two", "/Users/b"])
        let boxes = FavoriteTreemapLayout.place(t, in: panel)
        let parent = boxes.first { $0.path == "/Users/a" }!
        for child in boxes.filter({ $0.path.hasPrefix("/Users/a/") }) {
            XCTAssertTrue(parent.rect.insetBy(dx: -0.01, dy: -0.01).contains(child.rect),
                          "\(child.label) escaped its container")
            XCTAssertGreaterThanOrEqual(child.rect.minY,
                                        parent.rect.minY + FavoriteTreemapLayout.headerHeight - 0.01,
                                        "children must clear the title strip")
        }
    }

    func testSiblingsNeverOverlap() {
        let t = tree(["/a/one", "/a/two", "/b/three", "/b/four", "/c", "/d", "/e"])
        let boxes = FavoriteTreemapLayout.place(t, in: panel)
        let tops = boxes.filter { $0.depth == 0 }
        for i in tops.indices {
            for j in tops.indices where j > i {
                let hit = tops[i].rect.intersection(tops[j].rect)
                XCTAssertTrue(hit.isNull || hit.width < 0.01 || hit.height < 0.01,
                              "\(tops[i].label) overlaps \(tops[j].label)")
            }
        }
    }

    func testParentsComeBeforeChildren() {
        // Render order is z-order: children must paint over their box.
        let t = tree(["/Users/a", "/Users/a/one"])
        let boxes = FavoriteTreemapLayout.place(t, in: panel)
        XCTAssertLessThan(boxes.firstIndex { $0.path == "/Users/a" }!,
                          boxes.firstIndex { $0.path == "/Users/a/one" }!)
    }

    func testEveryNodeGetsABox() {
        // Nothing is ever dropped for being too small — the old layout
        // hid children when a container was cramped.
        let t = tree([
            "/Users/agent0/Projects", "/Users/agent1/Projects", "/srv/data",
            "/srv/data/logs", "/var/log",
        ])
        let boxes = FavoriteTreemapLayout.place(t, in: CGRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertEqual(Set(boxes.map(\.path)), Set(FavoriteTree.flatten(t).map(\.path)))
    }

    // MARK: Row breaking is optimal, not greedy

    /// dp must beat first-fit: packing the first row as full as possible
    /// can force a taller total. Whatever it returns, no other partition
    /// may be shorter.
    func testRowBreakingMinimisesTotalHeight() {
        let t = tree(["/alpha", "/beta", "/gamma", "/delta", "/epsilon"])
        let width: CGFloat = 300
        let chosen = FavoriteTreemapLayout.requiredHeight(t, width: width)
        // Brute force every partition into consecutive rows of the same
        // ordering and confirm none is shorter.
        let ordered = FavoriteTreemapLayout.order(t)
        var best = CGFloat.greatestFiniteMagnitude
        let n = ordered.count
        for mask in 0..<(1 << (n - 1)) {
            var rows: [[FavoriteTreeNode]] = []
            var row: [FavoriteTreeNode] = [ordered[0]]
            for i in 1..<n {
                if mask & (1 << (i - 1)) != 0 { rows.append(row); row = [] }
                row.append(ordered[i])
            }
            rows.append(row)
            guard rows.allSatisfy({ FavoriteTreemapLayout.fits($0, width: width) }) else { continue }
            let h = rows.map { FavoriteTreemapLayout.rowHeight($0, width: width) }.reduce(0, +)
                + FavoriteTreemapLayout.gap * CGFloat(rows.count - 1)
            best = min(best, h)
        }
        XCTAssertEqual(chosen, best, accuracy: 0.01,
                       "the DP must find the shortest legal partition")
    }

    // MARK: Width sharing

    /// Surplus width goes to the heavier box, so a folder holding six
    /// favorites still reads as bigger than one holding none.
    func testSurplusWidthFollowsWeight() {
        let t = tree(["/big", "/big/a", "/big/b", "/big/c", "/small"])
        let boxes = FavoriteTreemapLayout.place(t, in: CGRect(x: 0, y: 0, width: 700, height: 300))
        let big = boxes.first { $0.path == "/big" }!
        let small = boxes.first { $0.path == "/small" }!
        if abs(big.rect.minY - small.rect.minY) < 1 {   // only meaningful in one row
            XCTAssertGreaterThan(big.rect.width, small.rect.width)
        }
    }

    func testRowsFillTheAvailableHeight() {
        // No dead band at the bottom when the section is taller than the
        // layout needs — that was visible in the reported screenshot.
        let t = tree(["/a", "/b"])
        let tall = CGRect(x: 0, y: 0, width: 400, height: 500)
        let boxes = FavoriteTreemapLayout.place(t, in: tall)
        let bottom = boxes.map(\.rect.maxY).max() ?? 0
        XCTAssertEqual(bottom, tall.maxY, accuracy: 1.0)
    }

    // MARK: Sizing the section

    func testPreferredHeightIsWhatTheLayoutActuallyNeeds() {
        let t = tree((0..<12).map { "/some/folder\($0)" })
        let width: CGFloat = 360
        let h = FavoriteTreemapLayout.preferredHeight(for: t, width: width)
        XCTAssertEqual(h, FavoriteTreemapLayout.requiredHeight(t, width: width), accuracy: 0.01)
        let boxes = FavoriteTreemapLayout.place(t, in: CGRect(x: 0, y: 0, width: width, height: h))
        assertAllLegible(boxes)
    }

    func testPreferredHeightGrowsWithFavoriteCount() {
        let few = tree(["/a", "/b"])
        let many = tree((0..<20).map { "/dir\($0)" })
        let w: CGFloat = 360
        XCTAssertGreaterThan(FavoriteTreemapLayout.preferredHeight(for: many, width: w),
                             FavoriteTreemapLayout.preferredHeight(for: few, width: w))
        XCTAssertGreaterThanOrEqual(FavoriteTreemapLayout.preferredHeight(for: [], width: w), 96)
    }

    func testEmptyForestPlacesNothing() {
        XCTAssertTrue(FavoriteTreemapLayout.place([], in: panel).isEmpty)
    }

    func testStableAcrossCalls() {
        let t = tree(["/a/one", "/a/two", "/b", "/c/three"])
        XCTAssertEqual(FavoriteTreemapLayout.place(t, in: panel),
                       FavoriteTreemapLayout.place(t, in: panel),
                       "layout must not reshuffle between renders")
    }
}
