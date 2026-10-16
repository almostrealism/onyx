import XCTest
@testable import OnyxLib

/// Up to three top-level Timing projects at once, each with its own bars
/// and numbers; the legend is the union of their subprojects.
final class TimingMultiProjectTests: XCTestCase {

    // A tree: Work > (Onyx, Admin), Home > (Garden), Side (no children).
    private let projects = [
        TimingProject(id: "w", title: "Work", titleChain: ["Work"], color: "111111", parentID: nil, depth: 0),
        TimingProject(id: "w1", title: "Onyx", titleChain: ["Work", "Onyx"], color: "222222", parentID: "w", depth: 1),
        TimingProject(id: "w1a", title: "Bridge", titleChain: ["Work", "Onyx", "Bridge"], color: "", parentID: "w1", depth: 2),
        TimingProject(id: "w2", title: "Admin", titleChain: ["Work", "Admin"], color: "333333", parentID: "w", depth: 1),
        TimingProject(id: "h", title: "Home", titleChain: ["Home"], color: "444444", parentID: nil, depth: 0),
        TimingProject(id: "h1", title: "Garden", titleChain: ["Home", "Garden"], color: "555555", parentID: "h", depth: 1),
        TimingProject(id: "s", title: "Side", titleChain: ["Side"], color: "666666", parentID: nil, depth: 0),
    ]

    private var monday: Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 12
        return Calendar.current.date(from: c)!
    }

    private func row(_ day: String, _ id: String, hours: Double) -> TimingDataStore.ReportRow {
        let p = projects.first { $0.id == id }!
        return TimingDataStore.ReportRow(date: day, projectRef: id, projectTitle: p.title,
                                         projectColor: p.color, parentRef: p.parentID,
                                         titleChain: p.titleChain, seconds: hours * 3600)
    }

    private var rows: [TimingDataStore.ReportRow] {
        [
            row("2026-10-12", "w1", hours: 3),   // Work > Onyx
            row("2026-10-12", "w1a", hours: 1),  // Work > Onyx > Bridge → rolls up to Onyx
            row("2026-10-12", "w", hours: 0.5),  // time on Work itself
            row("2026-10-13", "w2", hours: 2),   // Work > Admin
            row("2026-10-12", "h1", hours: 1.5), // Home > Garden
            row("2026-10-14", "s", hours: 4),    // Side, unselected below
        ]
    }

    private func compute(_ ids: [String]) -> TimingManager.Computed {
        TimingManager.compute(rows: rows, projects: projects, filterIDs: ids,
                              monday: monday, today: monday.addingTimeInterval(86400 * 3))
    }

    func testOneGroupPerSelectedProjectInTheOrderChosen() {
        let r = compute(["h", "w"])
        XCTAssertEqual(r.groups.map(\.title), ["Home", "Work"])
        XCTAssertEqual(r.groups.map { $0.dailyHours.count }, [7, 7], "seven days each")
        XCTAssertEqual(r.groups[1].totalWeekHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(r.groups[0].totalWeekHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(r.groups[1].dailyHours[0].hours, 4.5, accuracy: 0.001, "Monday, Work")
    }

    func testRowsRollUpToTheSelectedProjectsDirectChildren() {
        let work = compute(["w"]).groups[0]
        let titles = Dictionary(uniqueKeysWithValues: work.projectTotals.map { ($0.title, $0.hours) })
        XCTAssertEqual(titles["Onyx"] ?? 0, 4, accuracy: 0.001, "Bridge is folded into Onyx")
        XCTAssertEqual(titles["Work"] ?? 0, 0.5, accuracy: 0.001,
                       "time logged to the project itself keeps its name")
        XCTAssertNil(titles["Bridge"])
    }

    /// The legend: every subproject across the selection, most time first,
    /// whichever project it's under. Unselected projects are left out.
    func testTheLegendIsTheUnionRankedByTime() {
        let combined = compute(["w", "h"]).combined
        XCTAssertEqual(combined.projectTotals.map(\.title), ["Onyx", "Admin", "Garden", "Work"])
        XCTAssertEqual(combined.totalWeekHours, 8, accuracy: 0.001, "Side is not selected")
    }

    /// Every bar in every group stacks its slices in the legend's order,
    /// so a band can be followed across days and projects.
    func testBarsStackInTheCombinedRanking() {
        let work = compute(["w", "h"]).groups[0]
        XCTAssertEqual(work.dailyHours[0].projects.map(\.projectTitle), ["Work", "Onyx"],
                       "smallest first, biggest at the bottom")
    }

    func testNothingSelectedIsOneAllGroup() {
        let r = compute([])
        XCTAssertEqual(r.groups.count, 1)
        XCTAssertEqual(r.groups[0].title, "All")
        XCTAssertEqual(r.groups[0].totalWeekHours, 12, accuracy: 0.001)
    }

    func testPerDayCountsOnlyDaysWithTime() {
        let work = compute(["w"]).groups[0]
        XCTAssertEqual(work.perDayThisWeek, 6.5 / 2, accuracy: 0.001, "Monday and Tuesday")
    }

    func testSelectionIsCappedAtThreeAndTogglesOff() {
        var list: [String] = []
        for id in ["a", "b", "c", "d"] { list = TimingManager.toggled(id, in: list) }
        XCTAssertEqual(list, ["a", "b", "c"], "a fourth is refused, not swapped in")
        XCTAssertEqual(TimingManager.toggled("b", in: list), ["a", "c"])
    }

    /// The fallback color for a project Timing gives none: the same every
    /// time, for the bars and the legend alike.
    func testFallbackColorsAreStable() {
        XCTAssertEqual(TimingManager.color("", for: "Bridge"), TimingManager.color("", for: "Bridge"))
        XCTAssertEqual(TimingManager.color("ABCDEF", for: "Bridge"), "ABCDEF")
        XCTAssertEqual(TimingManager.color("", for: "Bridge").count, 6)
    }

    // MARK: - The stats columns

    func testAColumnPerProjectThenTheTotal() {
        let r = compute(["w", "h"])
        let columns = TimingStatsGrid.columns(groups: r.groups, combined: r.combined)
        XCTAssertEqual(columns.map(\.label), ["Work", "Home", "total"])
        XCTAssertEqual(columns.last?.group.totalWeekHours ?? 0, 8, accuracy: 0.001,
                       "the total is every selected project together")
        XCTAssertNil(columns.last?.color, "the total has no project color")
    }

    /// One project's total would just repeat it, so there's one column.
    func testOneProjectIsOneColumn() {
        let r = compute(["w"])
        XCTAssertEqual(TimingStatsGrid.columns(groups: r.groups, combined: r.combined).map(\.label), ["Work"])
    }

    func testAllIsOneColumnCalledTotal() {
        let r = compute([])
        XCTAssertEqual(TimingStatsGrid.columns(groups: r.groups, combined: r.combined).map(\.label), ["total"])
    }
}
