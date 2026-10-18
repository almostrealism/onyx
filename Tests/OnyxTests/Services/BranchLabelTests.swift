import XCTest
@testable import OnyxLib

/// Prefixes are few and familiar, so they give up their characters first;
/// the last segment is what tells branches apart, so it keeps the most.
final class BranchLabelTests: XCTestCase {

    private func compact(_ s: String) -> String { BranchLabel.compact(s) }

    func testWhatFitsIsUntouched() {
        XCTAssertEqual(compact("fix/strip"), "fix/strip")
        XCTAssertEqual(compact("feature/timing"), "feature/timing")
        XCTAssertEqual(compact("main"), "main")
    }

    func testPrefixesShrinkBeforeAnythingIsCut() {
        XCTAssertEqual(compact("experiment/quant-welfare/phase-1"), "expe/quan/phase-1")
        XCTAssertEqual(compact("feature/multi-timing"), "feat/multi-timing")
    }

    func testTheCutGoesInsideTheLastSegment() {
        XCTAssertEqual(compact("feature/delta-consolidation"), "feat/delta-…dation")
        XCTAssertEqual(compact("qa/a-very-long-description-here"), "qa/a-very-…on-here")
    }

    func testNeverLongerThanTheLimit() {
        for b in ["experiment/quant-welfare/phase-1", "feature/delta-consolidation",
                  "a/b/c/d/e/f/g/h/i/j/k/l/the-actual-name", "no-slashes-but-very-long-indeed",
                  "/leading/slash/branch-name-here", "trailing/slash/"] {
            XCTAssertLessThanOrEqual(compact(b).count, 18, b)
        }
    }

    func testManyPrefixesFallBackToCuttingTheWhole() {
        // Prefixes alone would leave the name too little room to read.
        let deep = compact("a/b/c/d/e/f/g/h/i/j/k/l/the-actual-name")
        XCTAssertTrue(deep.contains("…"))
        XCTAssertTrue(deep.hasSuffix("name"))
    }

    func testNoSlashesIsAPlainMiddleCut() {
        XCTAssertEqual(compact("no-slashes-but-very-long-indeed"), "no-slashe…g-indeed")
    }
}
