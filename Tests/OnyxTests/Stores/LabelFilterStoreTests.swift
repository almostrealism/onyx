import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Which PR labels are shown: opt-in, from the labels the app has seen,
/// each remembered with its color.
final class LabelFilterStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: LabelFilterStore!

    override func setUp() {
        super.setUp()
        let suite = "LabelFilterStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = LabelFilterStore(defaults: defaults)
    }

    private func pr(_ labels: [PRLabel]) -> PullRequest {
        PullRequest(repoFullName: "o/r", number: 1, title: "t", url: "u",
                    openCommentThreads: 0, mergeStatus: .ready, labels: labels)
    }

    private let ready = PRLabel(name: "agent: ready", colorHex: "0e8a16")
    private let stuck = PRLabel(name: "agent: stuck", colorHex: "#D93F0B")
    private let size = PRLabel(name: "size/S", colorHex: "ededed")

    func testNothingIsShownUntilTheUserSaysSo() {
        store.noteSeen([ready, size])
        XCTAssertEqual(store.shown(pr([ready, size])), [])
        XCTAssertEqual(store.offered(), ["agent: ready", "size/S"])
    }

    /// The chosen ones, in the PR's own order.
    func testShowsOnlyTheChosenLabelsInThePRsOrder() {
        store.setIncluded("agent: stuck", true)
        store.setIncluded("agent: ready", true)
        XCTAssertEqual(store.shown(pr([stuck, size, ready])), [stuck, ready])
    }

    /// The settings list draws each label in the color it last had.
    func testRemembersEachLabelsColor() {
        store.noteSeen([ready, stuck])
        XCTAssertEqual(store.colors["agent: ready"], "0e8a16")
        XCTAssertEqual(store.colors["agent: stuck"], "d93f0b")
        store.noteSeen([PRLabel(name: "agent: ready", colorHex: "1d76db")])
        XCTAssertEqual(store.colors["agent: ready"], "1d76db")
    }

    func testTheChoicePersists() {
        store.setIncluded("agent: ready", true)
        XCTAssertTrue(LabelFilterStore(defaults: defaults).isIncluded("agent: ready"))
    }

    func testStaleLabelsDropOffUnlessIncluded() {
        let longAgo = Date().addingTimeInterval(-LabelFilterStore.memory - 1)
        store.noteSeen([size, ready], at: longAgo)
        store.setIncluded("agent: ready", true)
        XCTAssertEqual(store.offered(), ["agent: ready"])

        store.noteSeen([stuck])
        XCTAssertNil(store.seen["size/S"])
        XCTAssertNil(store.colors["size/S"], "nor is its color kept")
        XCTAssertNotNil(store.seen["agent: ready"])
    }

    func testTheSummaryExplainsAnEmptyOverlay() {
        XCTAssertTrue(PRLabelSettingsSection.summary(included: 0, offered: 3).contains("no labels"))
        XCTAssertEqual(PRLabelSettingsSection.summary(included: 2, offered: 3), "Showing 2 of 3")
    }
}

/// A label decodes from every shape the forges send it in.
final class PRLabelDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> [PRLabel] {
        try JSONDecoder().decode([PRLabel].self, from: Data(json.utf8))
    }

    func testGitHubsShape() throws {
        XCTAssertEqual(try decode(#"[{"name":"bug","color":"d73a4a"}]"#),
                       [PRLabel(name: "bug", colorHex: "d73a4a")])
    }

    /// GitLab with `with_labels_details`: a "#" and often upper case.
    func testGitLabsDetailedShape() throws {
        let labels = try decode(##"[{"id":1,"name":"bug","color":"#D73A4A","text_color":"#FFFFFF"}]"##)
        XCTAssertEqual(labels.first?.colorHex, "d73a4a")
    }

    /// A GitLab that ignores the parameter sends bare names. They still
    /// show, in a neutral gray rather than a white that looks chosen.
    func testGitLabsPlainNames() throws {
        XCTAssertEqual(try decode(#"["bug"]"#), [PRLabel(name: "bug", colorHex: "8a8a8a")])
    }

    func testAColorThatIsNotHexBecomesGray() {
        XCTAssertEqual(PRLabel(name: "x", colorHex: "red").colorHex, "8a8a8a")
        XCTAssertEqual(PRLabel(name: "x", colorHex: "#abc").colorHex, "8a8a8a")
    }
}
