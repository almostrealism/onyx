import XCTest
@testable import OnyxLib

/// The two problems the favorites treemap exists to solve:
/// same-named folders being indistinguishable, and a favorite inside
/// another favorite showing up as an unrelated sibling.
final class FavoriteTreeTests: XCTestCase {

    private func labels(_ nodes: [FavoriteTreeNode]) -> [String] {
        nodes.map(\.label)
    }

    // MARK: Nesting

    func testFavoriteInsideFavorite_nests() {
        let tree = FavoriteTree.build(paths: ["/Users/agent1", "/Users/agent1/Projects"])
        XCTAssertEqual(tree.count, 1, "the child must not be a second root")
        XCTAssertEqual(tree[0].path, "/Users/agent1")
        XCTAssertTrue(tree[0].isFavorite)
        XCTAssertEqual(labels(tree[0].children), ["Projects"])
    }

    func testNestsUnderDeepestFavoriteAncestor() {
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/Projects", "/Users/a/Projects/onyx",
        ])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].children.count, 1)
        // onyx belongs to Projects, not to the grandparent.
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["/Users/a/Projects/onyx"])
    }

    func testSiblingPrefixIsNotAnAncestor() {
        // /Users/ag must not swallow /Users/agent1 — component-wise, not
        // string-prefix, matching.
        let tree = FavoriteTree.build(paths: ["/Users/ag", "/Users/agent1"])
        XCTAssertEqual(tree.count, 2)
        XCTAssertTrue(tree.allSatisfy { $0.children.isEmpty })
    }

    // MARK: Ambiguity

    func testSameNamedFavorites_getImplicitParents() {
        let tree = FavoriteTree.build(paths: [
            "/Users/agent0/Projects", "/Users/agent1/Projects",
        ])
        XCTAssertEqual(labels(tree), ["agent0", "agent1"],
                       "the parents disambiguate — no two boxes labelled Projects")
        XCTAssertTrue(tree.allSatisfy { !$0.isFavorite },
                      "invented containers are not favorites and can't be removed")
        XCTAssertEqual(tree[0].children.map(\.path), ["/Users/agent0/Projects"])
        XCTAssertEqual(tree[1].children.map(\.path), ["/Users/agent1/Projects"])
        XCTAssertTrue(tree[0].children[0].isFavorite)
    }

    func testAmbiguityLiftsAsManyLevelsAsNeeded() {
        // One level up both parents are called "src" — keep going.
        let tree = FavoriteTree.build(paths: ["/a/src/x", "/b/src/x"])
        XCTAssertEqual(labels(tree), ["a", "b"])
        XCTAssertEqual(labels(tree[0].children), ["src"])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["/a/src/x"])
    }

    func testNoLiftWhenContainersAlreadyDiffer() {
        // Projects appears twice, but each already sits inside a
        // differently-named favorite — the boxes are distinguishable, so
        // nothing needs inventing.
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/Projects", "/Users/b", "/Users/b/Projects",
        ])
        XCTAssertEqual(labels(tree), ["a", "b"])
        XCTAssertTrue(tree.allSatisfy { $0.isFavorite }, "these are real favorites")
        XCTAssertEqual(labels(tree[0].children), ["Projects"])
        XCTAssertEqual(labels(tree[1].children), ["Projects"])
    }

    func testCollisionAmongChildrenOfTheSameContainerIsResolved() {
        // Both are inside /work but neither parent dir is a favorite.
        let tree = FavoriteTree.build(paths: ["/work", "/work/a/api", "/work/b/api"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(labels(tree[0].children), ["a", "b"])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["/work/a/api"])
    }

    /// A lift must never carry a node out of the container it belongs to.
    func testLiftNeverEscapesItsContainer() {
        let tree = FavoriteTree.build(paths: ["/work", "/work/a/api", "/work/b/api"])
        let inside = FavoriteTree.flatten(tree[0].children)
        XCTAssertTrue(inside.allSatisfy { $0.path.hasPrefix("/work/") },
                      "children of /work must all live under /work")
    }

    /// A top-level box has no container to identify it, so it must not
    /// share a label with anything else on screen — even something nested
    /// deep inside another box. Two cells both reading "Projects", one of
    /// them floating at the top level, is the original complaint.
    func testTopLevelBoxCollidesWithNestedLabelAnywhere() {
        let tree = FavoriteTree.build(paths: [
            "/Users/agent1", "/Users/agent1/Projects",   // nested Projects
            "/Users/agent0/Projects",                    // would be a bare root
        ])
        XCTAssertEqual(labels(tree), ["agent0", "agent1"])
        let agent0 = tree[0]
        XCTAssertFalse(agent0.isFavorite, "agent0 was invented for context")
        XCTAssertEqual(agent0.children.map(\.path), ["/Users/agent0/Projects"])
    }

    /// ...but a label that only ever appears nested is fine: those boxes
    /// are already told apart by the containers around them.
    func testNestedDuplicatesUnderDistinctContainersStayFlat() {
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/Projects", "/Users/b", "/Users/b/Projects",
        ])
        XCTAssertEqual(labels(tree), ["a", "b"])
        XCTAssertEqual(FavoriteTree.flatten(tree).count, 4, "nothing extra invented")
    }

    func testDistinctNamesAreLeftFlat() {
        let tree = FavoriteTree.build(paths: ["/Users/a/Projects", "/Users/b/Documents"])
        XCTAssertEqual(labels(tree).sorted(), ["Documents", "Projects"])
        XCTAssertTrue(tree.allSatisfy { $0.isFavorite && $0.children.isEmpty })
    }

    // MARK: Normalization

    func testTrailingSlashesAndDuplicatesCollapse() {
        let tree = FavoriteTree.build(paths: ["/Users/a/", "/Users/a", "/Users/a//"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].path, "/Users/a")
    }

    func testEmptyInput() {
        XCTAssertTrue(FavoriteTree.build(paths: []).isEmpty)
        XCTAssertTrue(FavoriteTree.build(paths: ["   "]).isEmpty)
    }

    func testRootFavoriteContainsEverything() {
        let tree = FavoriteTree.build(paths: ["/", "/Users/a"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].path, "/")
        XCTAssertEqual(tree[0].label, "/")
        XCTAssertEqual(tree[0].children.map(\.path), ["/Users/a"])
    }

    // MARK: Weight (treemap area)

    func testWeightCountsContainedFavorites() {
        let tree = FavoriteTree.build(paths: [
            "/Users/a", "/Users/a/one", "/Users/a/two", "/Users/b",
        ])
        let a = tree.first { $0.label == "a" }!
        let b = tree.first { $0.label == "b" }!
        XCTAssertEqual(a.weight, 3, "itself plus two children")
        XCTAssertEqual(b.weight, 1)
    }

    func testImplicitContainerWeightIsItsChildren() {
        let tree = FavoriteTree.build(paths: [
            "/Users/agent0/Projects", "/Users/agent1/Projects",
        ])
        // Implicit boxes don't count themselves — they're scaffolding.
        XCTAssertEqual(tree[0].weight, 1)
    }

    /// Nothing may be dropped: every saved path must appear exactly once
    /// in the forest, whatever restructuring happened.
    func testEveryFavoriteSurvivesTheBuild() {
        let paths = [
            "/Users/agent0/Projects", "/Users/agent1/Projects",
            "/Users/agent1", "/srv/data", "/srv/data/logs",
            "/a/src/x", "/b/src/x",
        ]
        let all = FavoriteTree.flatten(FavoriteTree.build(paths: paths))
        let favorites = all.filter(\.isFavorite).map(\.path).sorted()
        XCTAssertEqual(favorites, paths.sorted())
    }
}
