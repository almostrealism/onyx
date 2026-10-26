import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// The bottom strip's few slots go to whatever reports the highest
/// priority: containers by their CPU, PR jobs at a fixed 0.3, and nothing
/// that is already on screen elsewhere.
final class MonitorStripTests: XCTestCase {

    private func load(_ name: String, _ pct: Double) -> ContainerLoad {
        ContainerLoad(name: name, cpuText: "\(pct)%", cpuPercent: pct, maxPercent: 800)
    }

    private func job(_ pr: String, _ name: String = "build",
                     _ state: PRPipelineRun.ActiveJob.State = .running) -> PRJobActivity {
        PRJobActivity(prID: pr, branch: "feature-\(pr)", prTitle: "PR \(pr)",
                      prURL: "https://example.com/\(pr)", workflow: "CI",
                      job: name, state: state)
    }

    private func ids(_ items: [MonitorStripItem]) -> [String] { items.map(\.id) }

    private func pick(containers: [ContainerLoad], jobs: [PRJobActivity],
                      context: MonitorStripContext = .init(),
                      shownBefore: Set<String> = []) -> [String] {
        ids(MonitorStripRanker.select(
            from: [ContainerStripSource(loads: containers), PRJobStripSource(activities: jobs)],
            in: context, shownBefore: shownBefore))
    }

    // MARK: The examples this was designed from

    func testAPRJobSitsBetweenABusyAndAnIdleContainer() {
        let shown = pick(containers: [load("api", 50), load("db", 1)], jobs: [job("a")])
        XCTAssertEqual(shown, ["container:api", "prjob:a", "container:db"])
    }

    func testAContainerThatHeatsUpPassesThePRJob() {
        let shown = pick(containers: [load("api", 50), load("db", 40)], jobs: [job("a")])
        XCTAssertEqual(shown, ["container:api", "container:db", "prjob:a"])
    }

    func testASecondBusyPRPushesTheIdleContainerOff() {
        let shown = pick(containers: [load("api", 50), load("db", 1)],
                         jobs: [job("a"), job("b", "deploy", .queued)])
        XCTAssertEqual(shown, ["container:api", "prjob:a", "prjob:b"])
    }

    func testAPRJobTheSidePanelShowsGivesUpItsSlot() {
        let context = MonitorStripContext(prsInSidePanel: ["a"])
        let shown = pick(containers: [load("api", 50), load("db", 1)],
                         jobs: [job("a"), job("b")], context: context)
        XCTAssertEqual(shown, ["container:api", "prjob:b", "container:db"])
    }

    // MARK: Rules

    func testOnlyAsManyAsThereAreSlots() {
        let shown = pick(containers: (1...6).map { load("c\($0)", Double($0 * 10)) }, jobs: [])
        XCTAssertEqual(shown.count, MonitorStripRanker.slots)
        XCTAssertEqual(shown.first, "container:c6")
    }

    func testIdleContainersStillFillEmptySlots() {
        XCTAssertEqual(pick(containers: [load("quiet", 0)], jobs: []), ["container:quiet"])
    }

    func testZeroPriorityIsNeverShown() {
        let items = [MonitorStripItem(id: "x", priority: 0,
                                      content: .prJob(job("x")))]
        XCTAssertTrue(MonitorStripRanker.select(items).isEmpty)
    }

    func testPRJobsKeepTheirSourceOrderAmongThemselves() {
        // Busiest-first from the side panel's ordering; with one slot
        // left, the first wins.
        let shown = pick(containers: [load("a", 90), load("b", 80)],
                         jobs: [job("newest"), job("older")])
        XCTAssertEqual(shown, ["container:a", "container:b", "prjob:newest"])
    }

    func testNearTiesDontTradeTheLastSlotEveryPoll() {
        // db at 0.31 narrowly beats a PR job for the last slot…
        let before = pick(containers: [load("api", 90), load("web", 80), load("db", 31)],
                          jobs: [job("a")])
        XCTAssertEqual(before.last, "container:db")
        // …and a poll later at 0.29 it keeps it, because it's on screen.
        let after = pick(containers: [load("api", 90), load("web", 80), load("db", 29)],
                         jobs: [job("a")], shownBefore: Set(before))
        XCTAssertEqual(after, before)
        // A real drop does give the slot up.
        let dropped = pick(containers: [load("api", 90), load("web", 80), load("db", 5)],
                           jobs: [job("a")], shownBefore: Set(before))
        XCTAssertEqual(dropped.last, "prjob:a")
    }

    func testStickinessDecidesWhoNotWhere() {
        // Both on screen; order follows the raw priority.
        let shown = pick(containers: [load("db", 35)], jobs: [job("a")],
                         shownBefore: ["prjob:a", "container:db"])
        XCTAssertEqual(shown, ["container:db", "prjob:a"])
        let cooled = pick(containers: [load("db", 25)], jobs: [job("a")],
                          shownBefore: ["prjob:a", "container:db"])
        XCTAssertEqual(cooled, ["prjob:a", "container:db"])
    }

    // MARK: Building PR activity

    func testPRsWithNothingInFlightProduceNothing() {
        let busy = PullRequest(provider: .github, repoFullName: "o/r", number: 1,
                               title: "Busy", url: "u1", openCommentThreads: 0,
                               mergeStatus: .unknown, headBranch: "feat")
        let idle = PullRequest(provider: .github, repoFullName: "o/r", number: 2,
                               title: "Idle", url: "u2", openCommentThreads: 0,
                               mergeStatus: .unknown, headBranch: "")
        let running = PRPipelineRun(id: "r", prID: busy.id, name: "CI", overall: .running,
                                    runNumber: 1, attempt: 1, url: nil, updatedAt: nil,
                                    activeJob: .init(name: "unit", state: .running, since: nil))
        let source = PRJobStripSource(prs: [busy, idle]) { $0.id == busy.id ? [running] : [] }
        XCTAssertEqual(source.activities, [
            PRJobActivity(prID: busy.id, branch: "feat", prTitle: "Busy", prURL: "u1",
                          workflow: "CI", job: "unit", state: .running)
        ])
        XCTAssertEqual(PRJobStripSource.branchLabel(idle), "#2")
    }
}
