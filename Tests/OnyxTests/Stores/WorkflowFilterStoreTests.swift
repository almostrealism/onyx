import XCTest
@testable import OnyxLib

/// Which workflows show under an open PR: opt-in, from the names the app
/// has seen. Nothing on by default — most of a repo's workflows gate
/// nothing, and the list costs real estate.
final class WorkflowFilterStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: WorkflowFilterStore!

    override func setUp() {
        super.setUp()
        let suite = "WorkflowFilterStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = WorkflowFilterStore(defaults: defaults)
    }

    private func run(_ name: String) -> PRPipelineRun {
        PRPipelineRun(id: "x/\(name)", prID: "x", name: name, overall: .success,
                      runNumber: 1, attempt: 1, url: nil, updatedAt: nil)
    }

    /// The ask: start with none included.
    func testNothingIsShownUntilTheUserSaysSo() {
        store.noteSeen(["CI", "Running Copilot Code Review"])
        XCTAssertFalse(store.keeps(run("CI")))
        XCTAssertFalse(store.keeps(run("Running Copilot Code Review")))
        XCTAssertEqual(store.offered(), ["CI", "Running Copilot Code Review"],
                       "but both are offered, so the user can pick without typing")
    }

    func testSwitchingANameOnShowsItsRuns() {
        store.noteSeen(["CI", "Lint"])
        store.setIncluded("CI", true)
        XCTAssertTrue(store.keeps(run("CI")))
        XCTAssertFalse(store.keeps(run("Lint")))
        store.setIncluded("CI", false)
        XCTAssertFalse(store.keeps(run("CI")))
    }

    /// The choice survives a relaunch — it's the whole point of a store.
    func testTheChoicePersists() {
        store.setIncluded("CI", true)
        let again = WorkflowFilterStore(defaults: defaults)
        XCTAssertTrue(again.isIncluded("CI"))
        XCTAssertEqual(again.seen.count, 0)
    }

    /// A workflow deleted last spring shouldn't be offered forever — but
    /// one the user switched on stays listed however long it's been.
    func testStaleNamesDropOffUnlessIncluded() {
        let longAgo = Date().addingTimeInterval(-WorkflowFilterStore.memory - 1)
        store.noteSeen(["Old", "Kept"], at: longAgo)
        store.setIncluded("Kept", true)
        XCTAssertEqual(store.offered(), ["Kept"])

        // The next sighting of anything prunes the record itself.
        store.noteSeen(["CI"])
        XCTAssertNil(store.seen["Old"])
        XCTAssertNotNil(store.seen["Kept"])
    }

    func testSeeingANameAgainRefreshesIt() {
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        store.noteSeen(["CI"], at: earlier)
        store.noteSeen(["CI"], at: later)
        XCTAssertEqual(store.seen["CI"], later)
    }

    func testTheSummaryExplainsAnEmptyOverlay() {
        XCTAssertTrue(PRWorkflowSettingsSection.summary(included: 0, offered: 3)
            .contains("nothing appears"))
        XCTAssertEqual(PRWorkflowSettingsSection.summary(included: 1, offered: 3), "Showing 1 of 3")
    }
}
