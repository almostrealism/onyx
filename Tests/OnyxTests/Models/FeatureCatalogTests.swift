import XCTest
@testable import OnyxLib

final class FeatureCatalogTests: XCTestCase {

    private func f(_ id: String, _ place: FeaturePlace?) -> Feature {
        Feature(id: id, since: "0.20", title: id, detail: "", tip: id, place: place)
    }

    /// Ids are what a person's record is keyed by: a duplicate would
    /// retire two tips at once.
    func testIdsAreUnique() {
        let ids = FeatureCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// A tip has one line to live in.
    func testTipsAreShort() {
        for feature in FeatureCatalog.all {
            XCTAssertLessThanOrEqual(feature.tip.count, 64, feature.id)
        }
    }

    func testOnePlaceShowsItsOldestTipFirst() {
        let catalog = [f("a", .fileBrowser), f("b", .terminal), f("c", .fileBrowser)]
        XCTAssertEqual(FeatureCatalog.tip(at: .fileBrowser, retired: [], in: catalog)?.id, "a")
        XCTAssertEqual(FeatureCatalog.tip(at: .fileBrowser, retired: ["a"], in: catalog)?.id, "c")
        XCTAssertNil(FeatureCatalog.tip(at: .fileBrowser, retired: ["a", "c"], in: catalog))
        XCTAssertEqual(FeatureCatalog.tip(at: .terminal, retired: ["a"], in: catalog)?.id, "b")
    }

    func testAFeatureWithNoPlaceNeverTips() {
        let catalog = [f("a", nil)]
        for place in FeaturePlace.allCases {
            XCTAssertNil(FeatureCatalog.tip(at: place, retired: [], in: catalog))
        }
    }

    func testWhatsNewListsOnlyWhatWasntAnnounced() {
        let catalog = [f("a", nil), f("b", .terminal), f("c", nil)]
        XCTAssertEqual(FeatureCatalog.unannounced(announced: ["b"], in: catalog).map(\.id), ["a", "c"])
        XCTAssertTrue(FeatureCatalog.unannounced(announced: ["a", "b", "c"], in: catalog).isEmpty)
    }
}

final class FeatureTipStoreTests: XCTestCase {

    private let suite = "FeatureTipStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testUsingAFeatureRetiresItsTipForGood() {
        let store = FeatureTipStore(defaults: defaults)
        let first = store.tip(at: .fileBrowser)
        XCTAssertNotNil(first)
        store.used(first!.id)
        XCTAssertNotEqual(store.tip(at: .fileBrowser)?.id, first!.id)
        XCTAssertNotEqual(FeatureTipStore(defaults: defaults).tip(at: .fileBrowser)?.id, first!.id,
                          "a relaunch must not bring it back")
    }

    func testANewUserHasNothingAnnouncedAfterTheTour() {
        let store = FeatureTipStore(defaults: defaults)
        XCTAssertFalse(store.unannounced.isEmpty)
        store.markAllAnnounced()
        XCTAssertTrue(store.unannounced.isEmpty)
        XCTAssertTrue(FeatureTipStore(defaults: defaults).unannounced.isEmpty)
        XCTAssertNotNil(store.tip(at: .terminal), "the tour doesn't retire tips")
    }
}
