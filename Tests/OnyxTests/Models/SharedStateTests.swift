import XCTest
@testable import OnyxLib

/// The merge that decides whether a sync keeps or loses a note.
///
/// Every case here is a way someone's writing disappears, so they are
/// written as "what must survive" rather than "what the function returns".
/// The distinction that carries all the weight: a note missing from one
/// side is a DELETION only when we have a shadow proving that side once had
/// it. Without one it's simply news, and news never deletes.
final class SharedStateNoteMergeTests: XCTestCase {

    private func note(_ text: String, age: TimeInterval = 0) -> SessionNote {
        SessionNote(sessionID: "k", text: text, updated: Date().addingTimeInterval(-age))
    }

    private func merge(base: [String: SessionNote]?,
                       local: [String: SessionNote],
                       remote: [String: SessionNote]) -> [String: SessionNote] {
        SharedStateMerge.mergeNotes(base: base, local: local, remote: remote)
    }

    // MARK: - No shadow (first sync, or the user moved home host)

    func testWithoutAShadowBothSidesSurvive() {
        let merged = merge(base: nil,
                           local: ["a": note("mine")],
                           remote: ["b": note("theirs")])
        XCTAssertEqual(merged["a"]?.text, "mine")
        XCTAssertEqual(merged["b"]?.text, "theirs")
    }

    /// Adopting a host must never delete. The local copy not having a note
    /// the host has is not evidence of anything.
    func testWithoutAShadowNothingIsEverDeleted() {
        let merged = merge(base: nil, local: [:], remote: ["a": note("theirs")])
        XCTAssertEqual(merged["a"]?.text, "theirs")
        let other = merge(base: nil, local: ["a": note("mine")], remote: [:])
        XCTAssertEqual(other["a"]?.text, "mine")
    }

    func testWithoutAShadowTheNewerEditWins() {
        let merged = merge(base: nil,
                           local: ["a": note("older", age: 600)],
                           remote: ["a": note("newer", age: 10)])
        XCTAssertEqual(merged["a"]?.text, "newer")
    }

    // MARK: - Three-way

    func testADeletionOnTheOtherMachineIsHonoured() {
        let shared = note("both had this")
        let merged = merge(base: ["a": shared], local: ["a": shared], remote: [:])
        XCTAssertNil(merged["a"], "local never touched it, so the remote's deletion stands")
    }

    func testADeletionHereIsHonoured() {
        let shared = note("both had this")
        let merged = merge(base: ["a": shared], local: [:], remote: ["a": shared])
        XCTAssertNil(merged["a"])
    }

    func testAnEditHereBeatsUnchangedThere() {
        let old = note("old", age: 900)
        let merged = merge(base: ["a": old], local: ["a": note("edited")], remote: ["a": old])
        XCTAssertEqual(merged["a"]?.text, "edited")
    }

    func testTwoConcurrentEditsResolveToTheNewer() {
        let old = note("old", age: 9_000)
        let merged = merge(base: ["a": old],
                           local: ["a": note("mine", age: 600)],
                           remote: ["a": note("theirs", age: 10)])
        XCTAssertEqual(merged["a"]?.text, "theirs")
    }

    /// The asymmetry is deliberate: text someone wrote can't be recovered
    /// after a sync eats it, while deleting again is one keystroke.
    func testAnEditBeatsAConcurrentDeletion() {
        let old = note("old", age: 9_000)
        let kept = merge(base: ["a": old], local: ["a": note("still wanted")], remote: [:])
        XCTAssertEqual(kept["a"]?.text, "still wanted")
        let keptOther = merge(base: ["a": old], local: [:], remote: ["a": note("still wanted")])
        XCTAssertEqual(keptOther["a"]?.text, "still wanted")
    }

    func testANoteOnlyOneSideEverHadIsKept() {
        let merged = merge(base: [:], local: ["a": note("new here")], remote: [:])
        XCTAssertEqual(merged["a"]?.text, "new here")
    }

    func testAgreementNeedsNoRule() {
        let same = note("identical")
        let merged = merge(base: nil, local: ["a": same], remote: ["a": same])
        XCTAssertEqual(merged, ["a": same])
    }
}

/// Favourites merge by MEMBERSHIP. Which window shows a favourite is a
/// fact about one desk, not about the work.
final class SharedStateFavoriteMergeTests: XCTestCase {

    private func merge(base: [FavoriteEntry]?,
                       local: [FavoriteEntry],
                       remote: [FavoriteEntry]) -> [FavoriteEntry] {
        SharedStateMerge.mergeFavorites(base: base, local: local, remote: remote)
    }

    private func fav(_ id: String, windows: Set<Int> = [0]) -> FavoriteEntry {
        FavoriteEntry(sessionID: id, windows: windows)
    }

    func testRemoteAdditionsAreAppendedAfterLocalOrder() {
        let merged = merge(base: [], local: [fav("a"), fav("b")], remote: [fav("c")])
        XCTAssertEqual(merged.map(\.sessionID), ["a", "b", "c"])
    }

    func testLocalOrderIsPreserved() {
        let merged = merge(base: nil,
                           local: [fav("b"), fav("a")],
                           remote: [fav("a"), fav("b")])
        XCTAssertEqual(merged.map(\.sessionID), ["b", "a"],
                       "the user arranged the local order; the other machine's is not better")
    }

    func testWindowPlacementStaysLocal() {
        let merged = merge(base: nil,
                           local: [fav("a", windows: [2])],
                           remote: [fav("a", windows: [0, 1])])
        XCTAssertEqual(merged.first?.windows, [2])
    }

    func testUnfavouritingElsewhereIsHonouredWithAShadow() {
        let merged = merge(base: [fav("a"), fav("b")],
                           local: [fav("a"), fav("b")],
                           remote: [fav("a")])
        XCTAssertEqual(merged.map(\.sessionID), ["a"])
    }

    func testWithoutAShadowNothingIsUnfavourited() {
        let merged = merge(base: nil, local: [fav("a"), fav("b")], remote: [fav("a")])
        XCTAssertEqual(merged.map(\.sessionID), ["a", "b"])
    }

    func testAdditionsWinOverStaleAbsence() {
        // "c" is new locally and absent remotely; the shadow proves the
        // remote never had it, so it isn't a removal.
        let merged = merge(base: [fav("a")], local: [fav("a"), fav("c")], remote: [fav("a")])
        XCTAssertEqual(merged.map(\.sessionID), ["a", "c"])
    }
}

/// The bits around the merge: what counts as a change worth pushing, and
/// what the settings panel says.
final class SharedStateSyncTests: XCTestCase {

    func testAPushIsSkippedWhenOnlyTheTimestampDiffers() {
        let notes = ["a": SessionNote(sessionID: "a", text: "x")]
        let one = SharedState(notes: notes, favorites: [], updated: Date(), writtenBy: "laptop")
        let two = SharedState(notes: notes, favorites: [],
                              updated: Date().addingTimeInterval(-500), writtenBy: "studio")
        XCTAssertTrue(one.sameContent(as: two),
                      "otherwise two Macs on a timer rewrite the file at each other forever")
    }

    func testContentDifferencesAreSeen() {
        let one = SharedState(notes: ["a": SessionNote(sessionID: "a", text: "x")])
        let two = SharedState(notes: ["a": SessionNote(sessionID: "a", text: "y")])
        XCTAssertFalse(one.sameContent(as: two))
    }

    func testMergeStampsTheResultAsOurs() {
        let merged = SharedStateMerge.merge(
            base: nil,
            local: SharedState(writtenBy: "laptop"),
            remote: SharedState(writtenBy: "studio"))
        XCTAssertEqual(merged.writtenBy, "laptop",
                       "we are about to write the file, so we sign it")
    }

    // MARK: - Status text

    func testEveryStatusSaysWhatHappensToTheLocalCopy() {
        let waiting = SharedStateSync.statusLine(.waitingForHost, hostLabel: "studio",
                                                 lastWrittenBy: nil)
        XCTAssertTrue(waiting.contains("studio"))
        XCTAssertTrue(waiting.lowercased().contains("this mac"),
                      "an unreachable host must not read as data loss")

        let failed = SharedStateSync.statusLine(.failed("permission denied"),
                                                hostLabel: "studio", lastWrittenBy: nil)
        XCTAssertTrue(failed.contains("permission denied"), "say the host's own words")
        XCTAssertTrue(failed.lowercased().contains("unaffected"))
    }

    func testASyncedLineNamesTheOtherMachineWhenItWroteLast() {
        let line = SharedStateSync.statusLine(.synced(Date()), hostLabel: "studio",
                                              lastWrittenBy: "laptop")
        XCTAssertTrue(line.contains("laptop"))
    }

    /// Our own name adds nothing — of course this Mac wrote it.
    func testASyncedLineOmitsOurOwnName() {
        let line = SharedStateSync.statusLine(.synced(Date()), hostLabel: "studio",
                                              lastWrittenBy: SharedStateSync.thisMachine)
        XCTAssertFalse(line.contains(SharedStateSync.thisMachine))
    }

    func testLocalOnlyIsNotPhrasedAsAProblem() {
        let line = SharedStateSync.statusLine(.localOnly, hostLabel: nil, lastWrittenBy: nil)
        XCTAssertFalse(line.lowercased().contains("not synced"))
        XCTAssertTrue(line.lowercased().contains("this mac"))
    }

    func testAgoReadsLikeAPerson() {
        let now = Date()
        XCTAssertEqual(SharedStateSync.ago(now, now: now), "just now")
        XCTAssertEqual(SharedStateSync.ago(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(SharedStateSync.ago(now.addingTimeInterval(-7200), now: now), "2h ago")
        XCTAssertEqual(SharedStateSync.ago(now.addingTimeInterval(-86400 * 3), now: now), "3d ago")
    }

    // MARK: - Reading scp's complaints

    /// Hosts print login banners on stderr. Reporting the first line means
    /// reporting the banner, which explains nothing.
    func testTheFailureLineIsTheOneThatNamesTheFailure() {
        let stderr = """
        ==========================================
        Welcome to studio. All access is logged.
        ==========================================
        scp: /home/me/.onyx/shared-state.json: Permission denied
        """
        XCTAssertEqual(SharedStateSync.shortError(stderr),
                       "scp: /home/me/.onyx/shared-state.json: Permission denied")
    }

    func testNoStderrMeansNothingToReport() {
        XCTAssertNil(SharedStateSync.shortError("   \n  "))
    }

    func testAnUnrecognisedComplaintIsStillShown() {
        XCTAssertEqual(SharedStateSync.shortError("something odd happened"),
                       "something odd happened")
    }
}
