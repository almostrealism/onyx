import XCTest
@testable import OnyxLib

/// THE test that was missing. The previous attempt at this had thorough
/// unit tests of the key functions and none of what actually matters —
/// that a favourite and a note still resolve to a live session. The keys
/// were rewritten, the lookups weren't, everything went invisible, and
/// 980 tests passed while it happened.
///
/// So these assert resolution end to end, under every mixture of old and
/// new keys that can exist on disk during a migration.
final class StorageKeyResolutionTests: XCTestCase {

    private func makeState(host: HostConfig) -> AppState {
        let state = AppState()
        FavoritesStore.shared.reset()
        SessionNotesStore.shared.reset()
        state.hosts = [host]
        return state
    }

    private let host = HostConfig(label: "build",
                                  ssh: SSHConfig(host: "build.example.com", user: "me"))

    private func session(_ name: String, on host: HostConfig) -> TmuxSession {
        TmuxSession(name: name, source: .host(hostID: host.id))
    }

    // MARK: - Both key forms resolve

    func testAFavouriteStoredUnderTheLegacyKeyStillResolves() {
        let state = makeState(host: host)
        let s = session("api", on: host)
        state.allSessions = [s]

        // What an un-migrated favorites.json contains.
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: s.id,
                                                       windows: [state.windowIndex])]

        XCTAssertTrue(state.isFavorited(s))
        XCTAssertEqual(state.favoriteSessions.map(\.name), ["api"])
    }

    func testAFavouriteStoredUnderTheIdentityKeyResolves() {
        let state = makeState(host: host)
        let s = session("api", on: host)
        state.allSessions = [s]

        // What a migrated file will contain.
        FavoritesStore.shared.entries = [
            FavoriteEntry(sessionID: SessionIdentity.storageKey(for: s, host: host),
                          windows: [state.windowIndex])
        ]

        XCTAssertTrue(state.isFavorited(s))
        XCTAssertEqual(state.favoriteSessions.map(\.name), ["api"])
    }

    /// A half-migrated file — one entry rewritten, one not — has to work
    /// too, because a migration can be interrupted.
    func testAMixedFileResolvesEverything() {
        let state = makeState(host: host)
        let a = session("api", on: host)
        let b = session("web", on: host)
        state.allSessions = [a, b]

        FavoritesStore.shared.entries = [
            FavoriteEntry(sessionID: a.id, windows: [state.windowIndex]),
            FavoriteEntry(sessionID: SessionIdentity.storageKey(for: b, host: host),
                          windows: [state.windowIndex]),
        ]

        XCTAssertEqual(Set(state.favoriteSessions.map(\.name)), ["api", "web"])
    }

    func testNotesResolveUnderEitherKey() {
        let state = makeState(host: host)
        let legacy = session("api", on: host)
        let identity = session("web", on: host)
        state.allSessions = [legacy, identity]

        SessionNotesStore.shared.setNote("old key", for: legacy.id)
        SessionNotesStore.shared.setNote("new key",
                                         for: SessionIdentity.storageKey(for: identity, host: host))

        XCTAssertEqual(state.note(for: legacy)?.text, "old key")
        XCTAssertEqual(state.note(for: identity)?.text, "new key")

        let paired = SessionNotesStore.shared.activeNotes(in: state.allSessions,
                                                          keys: { state.storageKeys(for: $0) })
        XCTAssertEqual(Set(paired.map(\.session.name)), ["api", "web"])
    }

    // MARK: - Writing

    /// New writes use the identity key, so the file migrates itself as
    /// people touch things even before any bulk migration runs.
    func testNewFavouritesAreWrittenUnderTheIdentityKey() {
        let state = makeState(host: host)
        let s = session("api", on: host)
        state.allSessions = [s]

        state.toggleFavorite(s)
        XCTAssertEqual(FavoritesStore.shared.entries.first?.sessionID,
                       SessionIdentity.storageKey(for: s, host: host))
        XCTAssertTrue(state.isFavorited(s))
    }

    /// Un-favouriting something stored under the OLD key must remove it,
    /// not add a second entry under the new one.
    func testUnfavouritingALegacyEntryRemovesIt() {
        let state = makeState(host: host)
        let s = session("api", on: host)
        state.allSessions = [s]
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: s.id,
                                                       windows: [state.windowIndex])]

        state.toggleFavorite(s)
        XCTAssertFalse(state.isFavorited(s))
        XCTAssertTrue(FavoritesStore.shared.entries.isEmpty,
                      "the legacy entry should be gone, not shadowed by a new one")
    }

    // MARK: - Hosts we don't know

    /// A session whose host has been deleted still has to resolve to
    /// something rather than losing its note.
    func testAnUnknownHostFallsBackToTheLegacyKey() {
        let state = makeState(host: host)
        let orphan = TmuxSession(name: "api", source: .host(hostID: UUID()))
        XCTAssertEqual(state.storageKey(for: orphan), orphan.id)
        XCTAssertEqual(state.storageKeys(for: orphan), [orphan.id],
                       "no point offering a duplicate key when both are the same")
    }

    func testAKnownHostOffersBothKeysNewestFirst() {
        let state = makeState(host: host)
        let s = session("api", on: host)
        let keys = state.storageKeys(for: s)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], SessionIdentity.storageKey(for: s, host: host))
        XCTAssertEqual(keys[1], s.id)
    }
}

/// Step 2: the migration itself. The property that matters is not "the
/// keys changed" — it's that everything still resolves afterwards, which
/// is precisely what nobody checked last time.
final class StorageKeyMigrationTests: XCTestCase {

    private let host = HostConfig(label: "build",
                                  ssh: SSHConfig(host: "build.example.com", user: "me"))

    private func state() -> AppState {
        let s = AppState()
        FavoritesStore.shared.reset()
        SessionNotesStore.shared.reset()
        s.hosts = [host]
        return s
    }

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, source: .host(hostID: host.id))
    }

    /// Simulates what the launch path does, without touching disk.
    private func migrate(_ state: AppState) {
        var mapping: [String: String] = [:]
        for s in state.allSessions {
            let keys = state.storageKeys(for: s)
            if keys.count == 2 { mapping[keys[1]] = keys[0] }
        }
        SessionNotesStore.shared.rekey(mapping)
        var entries = state.favoriteEntries
        for i in entries.indices {
            if let new = mapping[entries[i].sessionID] { entries[i].sessionID = new }
        }
        state.favoriteEntries = entries
    }

    func testEverythingStillResolvesAfterMigrating() {
        let state = self.state()
        let s = session("api")
        state.allSessions = [s]
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: s.id,
                                                       windows: [state.windowIndex])]
        SessionNotesStore.shared.setNote("still here", for: s.id)

        migrate(state)

        // The assertion that was missing in the attempt that lost data.
        XCTAssertTrue(state.isFavorited(s))
        XCTAssertEqual(state.favoriteSessions.map(\.name), ["api"])
        XCTAssertEqual(state.note(for: s)?.text, "still here")
    }

    func testTheKeysActuallyMoved() {
        let state = self.state()
        let s = session("api")
        state.allSessions = [s]
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: s.id,
                                                       windows: [state.windowIndex])]
        migrate(state)
        XCTAssertEqual(FavoritesStore.shared.entries.first?.sessionID,
                       SessionIdentity.storageKey(for: s, host: host))
    }

    /// Runs on every launch, so it has to be a no-op the second time.
    func testMigratingTwiceChangesNothing() {
        let state = self.state()
        let s = session("api")
        state.allSessions = [s]
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: s.id,
                                                       windows: [state.windowIndex])]
        SessionNotesStore.shared.setNote("note", for: s.id)

        migrate(state)
        let afterFirst = FavoritesStore.shared.entries.map(\.sessionID)
        migrate(state)

        XCTAssertEqual(FavoritesStore.shared.entries.map(\.sessionID), afterFirst)
        XCTAssertEqual(SessionNotesStore.shared.notes.count, 1)
        XCTAssertEqual(state.note(for: s)?.text, "note")
    }

    /// A migration can be interrupted; the half-done state must work.
    func testAHalfMigratedFileResolvesAndFinishes() {
        let state = self.state()
        let a = session("api"), b = session("web")
        state.allSessions = [a, b]
        FavoritesStore.shared.entries = [
            FavoriteEntry(sessionID: a.id, windows: [state.windowIndex]),
            FavoriteEntry(sessionID: SessionIdentity.storageKey(for: b, host: host),
                          windows: [state.windowIndex]),
        ]

        XCTAssertEqual(Set(state.favoriteSessions.map(\.name)), ["api", "web"])
        migrate(state)
        XCTAssertEqual(Set(state.favoriteSessions.map(\.name)), ["api", "web"])
    }

    /// A note whose host is gone keeps its key and keeps resolving to
    /// nothing — but it is NOT deleted, so re-adding the host brings it
    /// back.
    func testAnOrphanedEntryIsNotDiscarded() {
        let state = self.state()
        let orphan = TmuxSession(name: "api", source: .host(hostID: UUID()))
        SessionNotesStore.shared.setNote("orphan", for: orphan.id)
        state.allSessions = []

        migrate(state)
        XCTAssertEqual(SessionNotesStore.shared.note(for: orphan.id)?.text, "orphan")
    }
}

/// Everything that MUTATES stored entries, exercised under both key
/// forms. These are the call sites the first two rounds of this work
/// missed: each one looked fine in isolation and silently did nothing
/// once storage moved to identity keys.
final class StorageKeyMutationTests: XCTestCase {

    private let host = HostConfig(label: "build",
                                  ssh: SSHConfig(host: "build.example.com", user: "me"))

    private func state() -> AppState {
        let s = AppState()
        FavoritesStore.shared.reset()
        SessionNotesStore.shared.reset()
        s.hosts = [host]
        return s
    }

    private func session(_ name: String) -> TmuxSession {
        TmuxSession(name: name, source: .host(hostID: host.id))
    }

    // MARK: - Per-window favourites

    func testWindowToggleFindsAnEntryUnderEitherKey() {
        for legacy in [true, false] {
            let state = self.state()
            let s = session("api")
            state.allSessions = [s]
            let key = legacy ? s.id : SessionIdentity.storageKey(for: s, host: host)
            FavoritesStore.shared.entries = [FavoriteEntry(sessionID: key, windows: [0])]

            state.toggleFavoriteWindow(s, windowIndex: 2)
            XCTAssertTrue(state.isFavoriteInWindow(s, windowIndex: 2),
                          "window toggle must find the entry (legacy key: \(legacy))")

            state.toggleFavoriteWindow(s, windowIndex: 2)
            XCTAssertFalse(state.isFavoriteInWindow(s, windowIndex: 2))
        }
    }

    // MARK: - Rename

    /// The session's NAME is part of its storage key, so a rename moves
    /// the key. Carrying the note across is the whole reason rename is
    /// more than a tmux call.
    func testRenameCarriesTheNoteAndTheFavouriteSlot() {
        let state = self.state()
        let before = session("old")
        let after = session("new")
        state.allSessions = [before]

        SessionNotesStore.shared.setNote("waiting on the migration",
                                         for: state.storageKey(for: before))
        FavoritesStore.shared.entries = [
            FavoriteEntry(sessionID: state.storageKey(for: before), windows: [state.windowIndex])
        ]

        state.migrateSessionIdentity(from: before, to: after)
        state.allSessions = [after]

        XCTAssertEqual(state.note(for: after)?.text, "waiting on the migration")
        XCTAssertTrue(state.isFavorited(after))
        XCTAssertNil(state.note(for: before), "the old key should not still hold it")
    }

    /// Same, for a session whose entries predate the migration.
    func testRenameCarriesEntriesStoredUnderTheLegacyKey() {
        let state = self.state()
        let before = session("old")
        let after = session("new")
        state.allSessions = [before]

        SessionNotesStore.shared.setNote("legacy", for: before.id)
        FavoritesStore.shared.entries = [FavoriteEntry(sessionID: before.id,
                                                       windows: [state.windowIndex])]

        state.migrateSessionIdentity(from: before, to: after)
        state.allSessions = [after]

        XCTAssertEqual(state.note(for: after)?.text, "legacy")
        XCTAssertTrue(state.isFavorited(after))
    }

    /// A rename must not renumber the bar: the entry is edited in place,
    /// so ⌘3 stays ⌘3.
    func testRenameKeepsItsPositionInTheBar() {
        let state = self.state()
        let a = session("a"), b = session("b"), c = session("c")
        state.allSessions = [a, b, c]
        for s in [a, b, c] { state.toggleFavorite(s) }

        let renamed = session("b-renamed")
        state.migrateSessionIdentity(from: b, to: renamed)
        state.allSessions = [a, renamed, c]

        XCTAssertEqual(state.favoriteSessions.map(\.name), ["a", "b-renamed", "c"])
    }

    // MARK: - Kill

    func testKillingASessionForgetsItsEntriesUnderEitherKey() {
        for legacy in [true, false] {
            let state = self.state()
            let s = session("api")
            state.allSessions = [s]
            let key = legacy ? s.id : SessionIdentity.storageKey(for: s, host: host)
            SessionNotesStore.shared.setNote("gone soon", for: key)
            FavoritesStore.shared.entries = [FavoriteEntry(sessionID: key,
                                                           windows: [state.windowIndex])]

            state.forgetSessionEntries(s)

            XCTAssertNil(state.note(for: s), "note should be cleared (legacy key: \(legacy))")
            XCTAssertFalse(state.isFavorited(s))
        }
    }
}
