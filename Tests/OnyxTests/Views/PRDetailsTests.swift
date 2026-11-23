import XCTest
import SwiftUI
import AppKit
@testable import OnyxCore
@testable import OnyxUI
@testable import OnyxLib

/// The PR details card: its words, where it goes, when it shows — and a
/// render, since hover itself can't be driven from a test. Set
/// ONYX_PRCARD_RENDER_DIR to look at the render.
@MainActor
final class PRDetailsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pr(_ provider: GitProvider = .github, threads: Int = 3,
                    status: PRMergeStatus = .blocked) -> PullRequest {
        PullRequest(provider: provider, repoFullName: "acme/api", number: 412,
                    title: "Retry policy for the ingest queue, with jittered backoff capped at thirty seconds",
                    url: "https://github.com/acme/api/pull/412", openCommentThreads: threads,
                    mergeStatus: status, headBranch: "ingest-retry", author: "mmurray",
                    labels: [PRLabel(name: "agent: ready for review", colorHex: "c06bff"),
                             PRLabel(name: "needs-human", colorHex: "ff6b6b")])
    }

    private var runs: [PRPipelineRun] {
        [PRPipelineRun(id: "a", prID: "p", name: "CI", overall: .running, runNumber: 812, attempt: 2,
                       url: nil, updatedAt: now.addingTimeInterval(-180),
                       activeJob: .init(name: "integration", state: .running, since: now.addingTimeInterval(-240))),
         PRPipelineRun(id: "b", prID: "p", name: "E2E", overall: .failure, runNumber: 77, attempt: 1,
                       url: nil, updatedAt: now.addingTimeInterval(-3600),
                       failedJobs: ["e2e (chrome)", "e2e (safari)", "e2e (firefox)", "visual"])]
    }

    // MARK: - Words

    func testReferenceUsesEachForgesMark() {
        XCTAssertEqual(PRDetails.reference(pr()), "acme/api#412")
        XCTAssertEqual(PRDetails.reference(pr(.gitlab)), "acme/api!412")
    }

    func testMergeStatesReadPlainly() {
        XCTAssertEqual(PRDetails.merge(.ready).tone, .good)
        XCTAssertEqual(PRDetails.merge(.conflicts).tone, .bad)
        XCTAssertEqual(PRDetails.merge(.checksFailing).text, "checks failing")
        XCTAssertEqual(PRDetails.merge(.unknown).tone, .quiet)
    }

    func testThreadsCountInWords() {
        XCTAssertNil(PRDetails.threads(0))
        XCTAssertEqual(PRDetails.threads(1), "1 unresolved thread")
        XCTAssertEqual(PRDetails.threads(4), "4 unresolved threads")
    }

    func testARunSaysItsNumberAttemptAndAge() {
        XCTAssertEqual(PRDetails.runMeta(runs[0], now: now), "#812 · attempt 2 · 3m ago")
        // A first attempt isn't worth a word.
        XCTAssertEqual(PRDetails.runMeta(runs[1], now: now), "#77 · 1h ago")
        XCTAssertEqual(PRDetails.activeJob(runs[0].activeJob!, now: now), "running integration for 4m")
    }

    // MARK: - Placement

    private let container = CGSize(width: 1400, height: 900)
    private let card = CGSize(width: 340, height: 220)

    func testBesideTheRowOnTheRightWhenItFits() {
        let row = CGRect(x: 500, y: 300, width: 400, height: 40)
        let p = PRDetails.placement(anchor: row, card: card, in: container)
        XCTAssertEqual(p.x, row.maxX + 10)
        XCTAssertEqual(p.y, row.minY)
    }

    func testOnTheLeftWhenTheRightIsTooNarrow() {
        let row = CGRect(x: 900, y: 300, width: 420, height: 40)
        let p = PRDetails.placement(anchor: row, card: card, in: container)
        XCTAssertEqual(p.x, row.minX - 10 - card.width)
    }

    func testNeverOffTheBottom() {
        let row = CGRect(x: 100, y: 860, width: 300, height: 30)
        let p = PRDetails.placement(anchor: row, card: card, in: container)
        XCTAssertEqual(p.y, container.height - card.height - 8)
    }

    /// The compact window: no room either side, so below the row (or
    /// above, near the bottom), and inside the window.
    func testANarrowWindowPutsItBelowOrAbove() {
        let narrow = CGSize(width: 320, height: 700)
        let small = CGSize(width: 304, height: 200)
        let top = PRDetails.placement(anchor: CGRect(x: 16, y: 100, width: 288, height: 20), card: small, in: narrow)
        XCTAssertEqual(top.y, 130)
        XCTAssertEqual(top.x, 8, "as far left as the margin allows: the card is nearly the window's width")
        let low = PRDetails.placement(anchor: CGRect(x: 16, y: 600, width: 288, height: 20), card: small, in: narrow)
        XCTAssertEqual(low.y, 390)
        XCTAssertLessThanOrEqual(low.x + small.width, narrow.width - 8 + 0.001)
    }

    // MARK: - Timing

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    func testItWaitsBeforeShowingAndSwapsAtOnceAfter() {
        let center = PRHoverCenter()
        let a = pr(), b = pr(.gitlab)
        center.enter(a, runs: [], anchor: .zero)
        XCTAssertNil(center.shown, "not on a passing sweep")
        wait(PRHoverCenter.showDelay + 0.1)
        XCTAssertEqual(center.shown?.pr.id, a.id)
        center.leave(a)
        center.enter(b, runs: [], anchor: .zero)
        XCTAssertEqual(center.shown?.pr.id, b.id, "moving between rows swaps it at once")
    }

    func testLeavingHidesAfterABeatAndCrossingAGapDoesNot() {
        let center = PRHoverCenter()
        let a = pr()
        center.enter(a, runs: [], anchor: .zero)
        wait(PRHoverCenter.showDelay + 0.1)
        center.leave(a)
        XCTAssertNotNil(center.shown, "not instantly — the pointer may be crossing to the next row")
        wait(PRHoverCenter.hideDelay + 0.1)
        XCTAssertNil(center.shown)
    }

    func testASweepThatLeavesInTimeShowsNothing() {
        let center = PRHoverCenter()
        let a = pr()
        center.enter(a, runs: [], anchor: .zero)
        center.leave(a)
        wait(PRHoverCenter.showDelay + 0.1)
        XCTAssertNil(center.shown)
    }

    // MARK: - Render

    func testTheCardRenders() throws {
        let view = PRDetailsCard(pr: pr(), runs: runs, accentColor: .onyxBlue)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
            .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, PRDetailsCard.width + 40, accuracy: 1)
        if let dir = ProcessInfo.processInfo.environment["ONYX_PRCARD_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pr-card.png"))
        }
    }
}
