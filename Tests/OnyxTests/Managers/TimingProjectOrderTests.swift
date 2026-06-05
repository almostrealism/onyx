import XCTest
@testable import OnyxLib

/// Pins the contract for the daily-hours bar chart's slice ordering.
/// The view stacks slices top-to-bottom; we want the largest *weekly
/// total* project to render last (= bottom) on every bar, and every
/// bar to share the same project order so the user can follow a single
/// colored band across the week.
final class TimingProjectOrderTests: XCTestCase {

    private func slice(_ name: String, hours: Double) -> TimingManager.ProjectSlice {
        TimingManager.ProjectSlice(projectTitle: name, color: "66CCFF", hours: hours)
    }

    private func day(_ label: String, projects: [TimingManager.ProjectSlice])
        -> TimingManager.DailyTime
    {
        TimingManager.DailyTime(
            id: label, dayLabel: label, date: Date(),
            hours: projects.reduce(0) { $0 + $1.hours },
            projects: projects
        )
    }

    private func total(_ name: String, hours: Double) -> TimingManager.ProjectTotal {
        TimingManager.ProjectTotal(title: name, color: "66CCFF", hours: hours)
    }

    func test_biggestWeeklyTotalProjectIsLastInEveryBar() {
        // Three projects with clear weekly totals: A=20h, B=10h, C=5h.
        let totals = [total("A", hours: 20), total("B", hours: 10), total("C", hours: 5)]

        // Two days with different per-day distributions — without the
        // consistent-order pass they'd render in different orders.
        let mon = day("Mon", projects: [
            slice("B", hours: 4),   // intentionally not sorted
            slice("A", hours: 6),
            slice("C", hours: 1),
        ])
        let tue = day("Tue", projects: [
            slice("A", hours: 3),
            slice("C", hours: 4),
            slice("B", hours: 2),
        ])

        let result = TimingManager.applyConsistentStackOrder(
            daily: [mon, tue], totals: totals)

        // Both days share the same project order, smallest weekly first.
        XCTAssertEqual(result[0].projects.map(\.projectTitle), ["C", "B", "A"])
        XCTAssertEqual(result[1].projects.map(\.projectTitle), ["C", "B", "A"])
    }

    func test_dayWithMissingProjectsKeepsConsistentRelativeOrder() {
        // Wednesday has no entries for project B. The remaining slices
        // must still be in C-then-A order so they slot into the same
        // visual position as the other days.
        let totals = [total("A", hours: 20), total("B", hours: 10), total("C", hours: 5)]
        let wed = day("Wed", projects: [slice("A", hours: 3), slice("C", hours: 2)])

        let result = TimingManager.applyConsistentStackOrder(
            daily: [wed], totals: totals)

        XCTAssertEqual(result[0].projects.map(\.projectTitle), ["C", "A"])
    }

    func test_unknownProjectSortsBeforeRankedOnes() {
        // A project missing from `totals` (defensive: weeklyRank lookup
        // defaults to 0) must end up at the TOP of the bar — i.e.
        // smaller than the smallest weekly-total project. This isn't a
        // visual goal so much as a "don't crash, don't randomly
        // reorder" contract.
        let totals = [total("A", hours: 10), total("B", hours: 5)]
        let mon = day("Mon", projects: [
            slice("A", hours: 4),
            slice("Mystery", hours: 1),
            slice("B", hours: 2),
        ])
        let result = TimingManager.applyConsistentStackOrder(
            daily: [mon], totals: totals)
        XCTAssertEqual(result[0].projects.map(\.projectTitle),
                       ["Mystery", "B", "A"])
    }
}
