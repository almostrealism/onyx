import XCTest
@testable import OnyxLib

/// A watch fires once, possibly weeks after it was set, and the user acts
/// on it immediately. So the two failure modes that matter are opposite
/// and equally bad: crying wolf, and staying silent. These pin both.
final class PageWatchEvaluationTests: XCTestCase {

    // MARK: - The first check can never fire

    /// Without this, every "disappears" watch announces itself the moment
    /// you create it (nothing was present before, so everything looks
    /// like a transition) — which teaches you to ignore the alert.
    func testFirstCheckEstablishesBaselineAndStaysQuiet() {
        let fresh = WatchState()
        XCTAssertFalse(fresh.evaluate(trigger: .appears, present: true, hash: "a"))
        XCTAssertFalse(fresh.evaluate(trigger: .disappears, present: false, hash: "a"))
        XCTAssertFalse(fresh.evaluate(trigger: .changes, present: false, hash: "a"))
    }

    // MARK: - Transitions

    func testAppearsFiresOnlyOnTheTransition() {
        let absent = WatchState(present: false, hash: "a")
        XCTAssertTrue(absent.evaluate(trigger: .appears, present: true, hash: "a"))

        let present = WatchState(present: true, hash: "a")
        XCTAssertFalse(present.evaluate(trigger: .appears, present: true, hash: "a"),
                       "still present is not news; it would re-fire on every poll")
    }

    func testDisappearsFiresOnlyOnTheTransition() {
        let present = WatchState(present: true, hash: "a")
        XCTAssertTrue(present.evaluate(trigger: .disappears, present: false, hash: "a"))

        let absent = WatchState(present: false, hash: "a")
        XCTAssertFalse(absent.evaluate(trigger: .disappears, present: false, hash: "a"))
    }

    func testChangesComparesHashes() {
        let seen = WatchState(present: false, hash: "aaa")
        XCTAssertTrue(seen.evaluate(trigger: .changes, present: false, hash: "bbb"))
        XCTAssertFalse(seen.evaluate(trigger: .changes, present: false, hash: "aaa"))
    }

    // MARK: - Runnability

    func testAWatchNeedsSomewhereToLookAndSomethingToLookFor() {
        XCTAssertFalse(PageWatch(label: "x", url: "", trigger: .appears, text: "hi").isRunnable)
        XCTAssertFalse(PageWatch(label: "x", url: "not a url", trigger: .appears, text: "hi").isRunnable)
        XCTAssertFalse(PageWatch(label: "x", url: "ftp://example.com", trigger: .appears, text: "hi").isRunnable,
                       "only http(s) — the fetcher speaks nothing else")
        XCTAssertFalse(PageWatch(label: "x", url: "https://example.com", trigger: .appears, text: "  ").isRunnable,
                       "a blank needle would match nothing forever, silently")
        XCTAssertTrue(PageWatch(label: "x", url: "https://example.com", trigger: .appears, text: "hi").isRunnable)
    }

    func testChangesNeedsNoText() {
        XCTAssertTrue(PageWatch(label: "x", url: "https://example.com",
                                trigger: .changes, text: "").isRunnable)
    }

    func testDisabledWatchesDoNotRun() {
        XCTAssertFalse(PageWatch(label: "x", url: "https://example.com", trigger: .appears,
                                 text: "hi", enabled: false).isRunnable)
    }

    /// Somebody else's server. A five-minute floor is the difference
    /// between a watch and a nuisance, and getting blocked right before
    /// the thing you were waiting for would be the worst outcome here.
    func testIntervalIsFloored() {
        XCTAssertEqual(PageWatch(label: "x", url: "https://e.com", intervalMinutes: 1).intervalMinutes,
                       PageWatch.minimumInterval)
        XCTAssertEqual(PageWatch(label: "x", url: "https://e.com", intervalMinutes: 60).intervalMinutes, 60)
    }

    // MARK: - The preset

    /// The preset watches Apple's own "coming later" notice rather than
    /// the string "512GB", which is already on that page three times —
    /// twice as a storage size, once inside the notice itself. Watching
    /// for it to APPEAR would fire instantly and mean nothing.
    func testMacStudioPresetWatchesTheNoticeDisappearing() {
        let preset = PageWatch.macStudioUltraMemory()
        XCTAssertEqual(preset.trigger, .disappears)
        XCTAssertTrue(preset.text.contains("512GB memory option"))
        XCTAssertTrue(preset.url.contains("apple.com"))
        XCTAssertTrue(preset.isRunnable)
        XCTAssertNotEqual(preset.text, "512GB",
                          "the bare string is already on the page and would cry wolf")
    }

    /// A full run of the sequence the preset expects to live through:
    /// baseline while Apple still says "coming late October", quiet polls
    /// for weeks, then the notice goes and it fires exactly once.
    func testPresetLifecycleFiresOnceWhenTheNoticeGoes() {
        var state = WatchState()
        let trigger = PageWatch.macStudioUltraMemory().trigger

        // First sighting: notice present, no news.
        XCTAssertFalse(state.evaluate(trigger: trigger, present: true, hash: "1"))
        state.present = true

        // Weeks of the page being edited around it.
        for hash in ["2", "3", "4"] {
            XCTAssertFalse(state.evaluate(trigger: trigger, present: true, hash: hash))
            state.present = true
        }

        // Launch day.
        XCTAssertTrue(state.evaluate(trigger: trigger, present: false, hash: "5"))
        state.present = false

        // And it doesn't keep firing afterwards.
        XCTAssertFalse(state.evaluate(trigger: trigger, present: false, hash: "6"))
    }
}
