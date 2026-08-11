import XCTest
import CoreGraphics
@testable import OnyxLib

/// The treemap has to behave like a set of buttons, not a picture: cells
/// must tile the area exactly (no gaps to click through, no overlaps that
/// steal each other's clicks), be proportional, and stay put between
/// renders.
final class TreemapTests: XCTestCase {

    private let area = CGRect(x: 0, y: 0, width: 400, height: 200)

    private func overlaps(_ rects: [CGRect]) -> Bool {
        for i in rects.indices {
            for j in rects.indices where j > i {
                let hit = rects[i].intersection(rects[j])
                if hit.width > 0.001 && hit.height > 0.001 { return true }
            }
        }
        return false
    }

    func testTilesTheRectExactly() {
        let rects = Treemap.layout(weights: [5, 3, 2, 2, 1, 1, 1], in: area)
        let covered = rects.reduce(0) { $0 + Double($1.width * $1.height) }
        XCTAssertEqual(covered, Double(area.width * area.height), accuracy: 0.5,
                       "cells must exactly fill the area")
        XCTAssertFalse(overlaps(rects), "overlapping cells would steal each other's clicks")
        for r in rects {
            XCTAssertTrue(area.insetBy(dx: -0.01, dy: -0.01).contains(r),
                          "cell \(r) escaped the area")
        }
    }

    func testAreasAreProportionalToWeights() {
        let weights: [Double] = [4, 2, 1, 1]
        let rects = Treemap.layout(weights: weights, in: area)
        let total = Double(area.width * area.height)
        for (w, r) in zip(weights, rects) {
            let expected = total * w / weights.reduce(0, +)
            XCTAssertEqual(Double(r.width * r.height), expected, accuracy: 1.0)
        }
    }

    func testResultsAreInInputOrder() {
        // Layout sorts internally (big first, for squareness) but the
        // caller's order must survive so rects line up with their nodes.
        let rects = Treemap.layout(weights: [1, 9, 1], in: area)
        XCTAssertGreaterThan(rects[1].width * rects[1].height,
                             rects[0].width * rects[0].height)
        XCTAssertEqual(Double(rects[0].width * rects[0].height),
                       Double(rects[2].width * rects[2].height), accuracy: 1.0)
    }

    func testEqualWeightsProduceUsableAspectRatios() {
        // The whole reason for squarifying: 8 equal cells in a 2:1 area
        // should be blocks, not slivers.
        let rects = Treemap.layout(weights: Array(repeating: 1, count: 8), in: area)
        for r in rects {
            let ratio = max(r.width / r.height, r.height / r.width)
            XCTAssertLessThan(ratio, 3.0, "cell \(r) is too thin to be a button")
        }
    }

    func testStableAcrossCalls() {
        let a = Treemap.layout(weights: [3, 1, 1, 2], in: area)
        let b = Treemap.layout(weights: [3, 1, 1, 2], in: area)
        XCTAssertEqual(a, b, "same input must not reshuffle between renders")
    }

    func testSingleItemFillsEverything() {
        XCTAssertEqual(Treemap.layout(weights: [1], in: area), [area])
    }

    func testDegenerateInputs() {
        XCTAssertTrue(Treemap.layout(weights: [], in: area).isEmpty)
        XCTAssertEqual(Treemap.layout(weights: [1, 2], in: .zero), [.zero, .zero])
        // Zero and negative weights still get a (tiny) cell rather than
        // vanishing without trace.
        let rects = Treemap.layout(weights: [0, -5, 10], in: area)
        XCTAssertEqual(rects.count, 3)
        XCTAssertFalse(overlaps(rects))
    }
}

/// Placement: the recursive step that turns the forest into positioned
/// boxes, including containment and the "too small to nest" fallback.
final class FavoriteTreemapLayoutTests: XCTestCase {

    private let area = CGRect(x: 0, y: 0, width: 420, height: 260)

    func testChildrenAreDrawnInsideTheirParent() {
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/one", "/Users/a/two", "/Users/b",
        ])
        let placed = FavoriteTreemapLayout.place(tree, in: area)
        let parent = placed.boxes.first { $0.path == "/Users/a" }!
        let child = placed.boxes.first { $0.path == "/Users/a/one" }!
        XCTAssertTrue(parent.rect.insetBy(dx: -0.01, dy: -0.01).contains(child.rect),
                      "a nested favorite must render inside its container")
        XCTAssertGreaterThan(child.rect.minY, parent.rect.minY,
                             "children sit below the container's title strip")
        XCTAssertFalse(placed.truncated)
    }

    func testParentsComeBeforeChildren() {
        // Render order == z-order: children must paint on top so they own
        // clicks inside their own area.
        let tree = FavoriteTree.build(paths: ["/Users/a", "/Users/a/one"])
        let boxes = FavoriteTreemapLayout.place(tree, in: area).boxes
        let parentIdx = boxes.firstIndex { $0.path == "/Users/a" }!
        let childIdx = boxes.firstIndex { $0.path == "/Users/a/one" }!
        XCTAssertLessThan(parentIdx, childIdx)
    }

    func testEveryNodeGetsABox() {
        let tree = FavoriteTree.build(paths: [
            "/Users/agent0/Projects", "/Users/agent1/Projects", "/srv/data",
        ])
        let boxes = FavoriteTreemapLayout.place(tree, in: area).boxes
        XCTAssertEqual(Set(boxes.map(\.path)),
                       Set(FavoriteTree.flatten(tree).map(\.path)))
    }

    func testImplicitContainersAreMarkedNotFavorite() {
        let tree = FavoriteTree.build(paths: [
            "/Users/agent0/Projects", "/Users/agent1/Projects",
        ])
        let boxes = FavoriteTreemapLayout.place(tree, in: area).boxes
        let container = boxes.first { $0.path == "/Users/agent0" }!
        XCTAssertFalse(container.isFavorite, "so the UI won't offer to remove it")
        XCTAssertTrue(container.hasChildren)
        XCTAssertTrue(boxes.first { $0.path == "/Users/agent0/Projects" }!.isFavorite)
    }

    /// In a cramped panel a container can't show its children legibly.
    /// It renders as one box and reports truncation — the caller can say
    /// so instead of silently losing a favorite.
    func testTooSmallToNestReportsTruncation() {
        let tree = FavoriteTree.build(paths: ["/Users/a", "/Users/a/one"])
        let tiny = CGRect(x: 0, y: 0, width: 50, height: 24)
        let placed = FavoriteTreemapLayout.place(tree, in: tiny)
        XCTAssertTrue(placed.truncated)
        XCTAssertFalse(placed.boxes.first { $0.path == "/Users/a" }?.hasChildren ?? true)
    }

    func testPreferredHeightGrowsWithFavoriteCount() {
        let few = FavoriteTree.build(paths: ["/a", "/b"])
        let many = FavoriteTree.build(paths: (0..<20).map { "/dir\($0)" })
        let w: CGFloat = 360
        XCTAssertGreaterThan(FavoriteTreemapLayout.preferredHeight(for: many, width: w),
                             FavoriteTreemapLayout.preferredHeight(for: few, width: w))
        XCTAssertGreaterThanOrEqual(FavoriteTreemapLayout.preferredHeight(for: [], width: w), 96)
    }

    /// A favorite that doesn't fit isn't drawn — so the height must grow
    /// until everything fits rather than quietly hiding one.
    func testFittingHeightGrowsUntilNothingIsTruncated() {
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/one", "/Users/a/two", "/Users/a/three",
            "/Users/b", "/Users/b/x", "/Users/b/y",
        ])
        let width: CGFloat = 240
        let height = FavoriteTreemapLayout.fittingHeight(for: tree, width: width)
        let placed = FavoriteTreemapLayout.place(
            tree, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertFalse(placed.truncated)
        XCTAssertEqual(Set(placed.boxes.map(\.path)),
                       Set(FavoriteTree.flatten(tree).map(\.path)),
                       "every favorite must have a box to click")
    }

    func testEmptyForestPlacesNothing() {
        let placed = FavoriteTreemapLayout.place([], in: area)
        XCTAssertTrue(placed.boxes.isEmpty)
        XCTAssertFalse(placed.truncated)
    }
}
