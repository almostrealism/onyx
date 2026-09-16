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

    func testADeletionOnTheOtherMachineIsHonored() {
        let shared = note("both had this")
        let merged = merge(base: ["a": shared], local: ["a": shared], remote: [:])
        XCTAssertNil(merged["a"], "local never touched it, so the remote's deletion stands")
    }

    func testADeletionHereIsHonored() {
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

/// Favorites merge by MEMBERSHIP. Which window shows a favorite is a
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

    func testUnfavoritingElsewhereIsHonoredWithAShadow() {
        let merged = merge(base: [fav("a"), fav("b")],
                           local: [fav("a"), fav("b")],
                           remote: [fav("a")])
        XCTAssertEqual(merged.map(\.sessionID), ["a"])
    }

    func testWithoutAShadowNothingIsUnfavorited() {
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

    func testAnUnrecognizedComplaintIsStillShown() {
        XCTAssertEqual(SharedStateSync.shortError("something odd happened"),
                       "something odd happened")
    }
}

/// How quickly one Mac sees the other's change.
///
/// The budget is end-to-end and stated as a promise to the user: a note
/// written (or cleared) on one machine should be on the other inside about
/// a minute. That is the write-side debounce plus the read-side poll, so
/// both halves are asserted here — changing either one silently changes
/// what the feature is.
final class SharedStateCadenceTests: XCTestCase {

    /// The number that matters. 4s debounce + 60s poll ≈ 64s worst case,
    /// ~34s average.
    func testTheEndToEndBudgetIsAboutAMinute() {
        let worstCase = SharedStateSync.Cadence.active + 4
        XCTAssertLessThanOrEqual(worstCase, 70,
                                 "a change should reach the other machine inside about a minute")
    }

    func testAnIdleMacBacksOff() {
        XCTAssertGreaterThan(SharedStateSync.Cadence.idle,
                             SharedStateSync.Cadence.active,
                             "a screen nobody is looking at doesn't need minute-by-minute polling")
    }

    func testAFirstTickAlwaysRuns() {
        XCTAssertTrue(SharedStateSync.Cadence.shouldRun(now: Date(), lastAttempt: nil,
                                                        isActive: false))
    }

    func testAnActiveMacPollsAtTheActiveInterval() {
        let now = Date()
        let justBefore = now.addingTimeInterval(-(SharedStateSync.Cadence.active - 1))
        XCTAssertFalse(SharedStateSync.Cadence.shouldRun(now: now, lastAttempt: justBefore,
                                                         isActive: true))
        let due = now.addingTimeInterval(-SharedStateSync.Cadence.active)
        XCTAssertTrue(SharedStateSync.Cadence.shouldRun(now: now, lastAttempt: due,
                                                        isActive: true))
    }

    /// The same elapsed time is due when you're looking and not when
    /// you aren't — that IS the back-off.
    func testAnIdleMacSkipsTicksThatAnActiveOneWouldTake() {
        let now = Date()
        let aMinuteAgo = now.addingTimeInterval(-SharedStateSync.Cadence.active)
        XCTAssertTrue(SharedStateSync.Cadence.shouldRun(now: now, lastAttempt: aMinuteAgo,
                                                        isActive: true))
        XCTAssertFalse(SharedStateSync.Cadence.shouldRun(now: now, lastAttempt: aMinuteAgo,
                                                         isActive: false))
    }

    func testAnIdleMacStillPollsEventually() {
        let now = Date()
        let longAgo = now.addingTimeInterval(-SharedStateSync.Cadence.idle)
        XCTAssertTrue(SharedStateSync.Cadence.shouldRun(now: now, lastAttempt: longAgo,
                                                        isActive: false))
    }

    /// Activation syncs immediately — walking back to a Mac is exactly when
    /// you expect to see what the other one did — but ⌘-tabbing repeatedly
    /// must not turn into a poll loop.
    func testTheActivationThrottleIsShortButNotZero() {
        XCTAssertGreaterThan(SharedStateSync.Cadence.activationThrottle, 0)
        XCTAssertLessThan(SharedStateSync.Cadence.activationThrottle,
                          SharedStateSync.Cadence.active,
                          "activation must beat the regular tick or it adds nothing")
    }
}

/// Tracked pipelines travel with notes and favorites.
///
/// Matched on the PARSED id, not the URL text. The same pipeline has
/// several spellings — a trailing slash, http vs https, a pasted trailing
/// newline — and two machines that added it by different routes must end
/// up with ONE entry, since duplicates produce colliding ids downstream.
///
/// Note what is deliberately NOT collapsed: a workflow page and a run page
/// on the same repo are different targets (track-over-time vs one frozen
/// run) and keep separate ids, so both survive.
final class SharedStatePipelineMergeTests: XCTestCase {

    private func merge(base: [String]?, local: [String], remote: [String]) -> [String] {
        SharedStateMerge.mergePipelines(base: base, local: local, remote: remote)
    }

    private let workflowPage =
        "https://github.com/acme/api/actions/workflows/ci.yml"
    private let runPage =
        "https://github.com/acme/api/actions/runs/123456"

    func testAPipelineAddedElsewhereArrives() {
        let merged = merge(base: [], local: [], remote: [workflowPage])
        XCTAssertEqual(merged, [workflowPage])
    }

    func testRemovingOneElsewhereRemovesItHere() {
        let merged = merge(base: [workflowPage], local: [workflowPage], remote: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testWithoutAShadowNothingIsRemoved() {
        let merged = merge(base: nil, local: [workflowPage], remote: [])
        XCTAssertEqual(merged, [workflowPage], "adopting a host must not untrack anything")
    }

    /// The same pipeline reached by two routes is one pipeline.
    func testTwoSpellingsOfOnePipelineCollapse() throws {
        let withSlash = workflowPage + "/"
        XCTAssertEqual(PipelineSpec.parse(workflowPage)?.id,
                       PipelineSpec.parse(withSlash)?.id,
                       "premise: these are the same pipeline to the parser")

        let merged = merge(base: [], local: [workflowPage], remote: [withSlash])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first, workflowPage, "the local spelling is the one typed here")
    }

    /// …but two genuinely different targets on the same repo both stay.
    func testAWorkflowAndAFrozenRunAreNotTheSamePipeline() {
        XCTAssertNotEqual(PipelineSpec.parse(workflowPage)?.id,
                          PipelineSpec.parse(runPage)?.id)
        let merged = merge(base: [], local: [workflowPage], remote: [runPage])
        XCTAssertEqual(merged.count, 2)
    }

    func testLocalOrderIsKeptAndRemoteAdditionsAppended() {
        let a = "https://github.com/acme/a/actions/workflows/ci.yml"
        let b = "https://github.com/acme/b/actions/workflows/ci.yml"
        let c = "https://github.com/acme/c/actions/workflows/ci.yml"
        XCTAssertEqual(merge(base: [], local: [b, a], remote: [c]), [b, a, c])
    }

    func testDuplicatesAlreadyInTheListAreCollapsed() {
        let merged = merge(base: nil, local: [workflowPage, workflowPage], remote: [])
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - The bundle

    /// A token is a credential for one person on one machine. Putting one
    /// in a file on a shared host to save typing it twice is not a trade
    /// this feature gets to make for the user.
    func testTokensAreNotInTheSharedBundle() throws {
        var state = SharedState()
        state.githubPipelines = ["https://github.com/acme/api/actions/workflows/ci.yml"]
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(state), encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertTrue(json.contains("githubPipelines"))
    }

    /// Adding a field must never stop two machines syncing. The
    /// synthesized decoder requires every key — so this type decodes field
    /// by field, and a file written before pipelines existed still reads.
    func testAFileFromAnOlderVersionStillDecodes() throws {
        let old = """
        {"notes":{},"favorites":[],"updated":"2026-01-01T00:00:00Z","writtenBy":"laptop"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SharedState.self, from: Data(old.utf8))
        XCTAssertEqual(state.writtenBy, "laptop")
        XCTAssertTrue(state.githubPipelines.isEmpty)
        XCTAssertTrue(state.gitlabPipelines.isEmpty)
    }

    /// …and one from a FUTURE version, with fields we don't know, must not
    /// throw either — the sync refuses to overwrite what it can't read.
    func testAFileFromANewerVersionStillDecodes() throws {
        let future = """
        {"notes":{},"favorites":[],"somethingNew":{"a":1},"writtenBy":"studio"}
        """
        let state = try JSONDecoder().decode(SharedState.self, from: Data(future.utf8))
        XCTAssertEqual(state.writtenBy, "studio")
    }

    func testPipelineChangesCountAsAContentChangeWorthPushing() {
        var a = SharedState()
        var b = SharedState()
        b.githubPipelines = ["https://github.com/acme/api/actions/workflows/ci.yml"]
        XCTAssertFalse(a.sameContent(as: b))
        a.githubPipelines = b.githubPipelines
        XCTAssertTrue(a.sameContent(as: b))
    }
}

/// The wipe.
///
/// From a real event log, one machine, no other Onyx connected:
///
///   2:24  shared state: no copy at mac-studio:.onyx/shared-state.json yet
///   2:29  mac-studio: no marker over a plain pipe — retrying with a terminal
///   3:03  mac-studio: failed over to standby connection
///   3:12  shared state synced with mac-studio: 0 notes, 0 favorites, 0 pipelines
///
/// A fetch came back empty-handed while the connection was flapping. The
/// sync merged against `.empty`, and with a shadow in hand the three-way
/// merge reads "in the shadow, absent from the remote" as a DELETION — so
/// it deleted everything, then pushed the emptiness to the host, where the
/// next machine would have picked it up as the truth.
///
/// A missing file is not a deletion. It is the absence of evidence, and
/// the transfer that reports it is the same transfer that fails when the
/// network is unhappy.
final class SharedStateWipeTests: XCTestCase {

    private func populated() -> SharedState {
        SharedState(notes: ["a": SessionNote(sessionID: "a", text: "keep me")],
                    favorites: [FavoriteEntry(sessionID: "a", windows: [0])],
                    githubPipelines: ["https://github.com/acme/api/actions/workflows/ci.yml"])
    }

    /// The merge itself, at the moment it went wrong: shadow present,
    /// local intact, remote reporting nothing.
    func testMergingAgainstAnEmptyRemoteWouldHaveDeletedEverything() {
        let state = populated()
        let merged = SharedStateMerge.merge(base: state, local: state, remote: .empty)
        XCTAssertTrue(merged.isEmpty,
                      """
                      This is the BUG, asserted so the reasoning stays visible: a \
                      three-way merge against an empty remote is a total deletion. \
                      The fix is never to call it with one — see the refusal below \
                      and SharedStateSync's handling of a missing copy.
                      """)
    }

    // MARK: - The backstop

    func testEmptyingEverythingInOneStepIsRefused() {
        let refusal = SharedStateSync.refusal(previous: populated(), next: .empty)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("1 notes") == true, "say what was at stake")
        XCTAssertTrue(refusal?.contains("nothing was changed") == true)
    }

    /// A fresh machine with nothing on it must still be able to sync.
    func testAnEmptyStateIsFineWhenThereWasNothingToLose() {
        XCTAssertNil(SharedStateSync.refusal(previous: .empty, next: .empty))
    }

    /// Ordinary deletions are still allowed — the guard is about losing
    /// EVERYTHING at once, not about losing anything.
    func testClearingTheLastNoteIsAllowedWhileOtherThingsRemain() {
        let before = populated()
        var after = before
        after.notes = [:]
        XCTAssertNil(SharedStateSync.refusal(previous: before, next: after))
    }

    func testRemovingMostThingsIsAllowed() {
        var after = SharedState()
        after.notes = ["a": SessionNote(sessionID: "a", text: "the only survivor")]
        XCTAssertNil(SharedStateSync.refusal(previous: populated(), next: after))
    }

    // MARK: - Backups

    /// The user's rule: a backup must never be replaced by a copy with
    /// nothing in it, because that is exactly when it is needed. Otherwise
    /// the data is lost twice — once in the file, once in the backup on
    /// the next tick.
    func testTheRemoteBackupIsTakenWhenWritingRealContent() {
        let script = SharedStateSync.moveIntoPlaceScript(backingUp: true)
        XCTAssertTrue(script.contains("cp "), script)
        XCTAssertTrue(script.contains(SharedStateSync.backupFilename))
        XCTAssertTrue(script.contains("mv "), "and the move still happens")
    }

    func testTheRemoteBackupIsNotTouchedWhenWritingNothing() {
        let script = SharedStateSync.moveIntoPlaceScript(backingUp: false)
        XCTAssertFalse(script.contains("cp "),
                       "an empty write must leave the last good backup alone")
        XCTAssertFalse(script.contains(SharedStateSync.backupFilename))
        XCTAssertTrue(script.contains("mv "))
    }

    /// Both remote paths are scp paths: no shell expansion (see the SFTP
    /// lesson), and the backup sits beside the file it backs up.
    func testTheBackupPathIsFetchableByScp() {
        XCTAssertFalse(SharedStateSync.remoteBackupPath.contains("$"))
        XCTAssertTrue(SharedStateSync.remoteBackupPath.hasPrefix(".onyx/"))
        XCTAssertTrue(SharedStateSync.moveIntoPlaceScript(backingUp: true)
            .contains(SharedStateSync.backupFilename))
    }

    func testIsEmptyMeansAllOfIt() {
        XCTAssertTrue(SharedState.empty.isEmpty)
        XCTAssertFalse(populated().isEmpty)
        var onlyPipelines = SharedState()
        onlyPipelines.gitlabPipelines = ["https://gitlab.com/a/b/-/pipelines/1"]
        XCTAssertFalse(onlyPipelines.isEmpty, "one entry anywhere is not empty")
    }
}
