//
// SessionNotesStore.swift
//
// Responsibility: Owns the per-session status notes the user attaches to
//                 tmux sessions ("waiting on test result for fine-tuning",
//                 etc). Persists to JSON keyed by TmuxSession.id.
// Scope: Shared singleton (SessionNotesStore.shared) — all windows read
//        and write through it; the monitor view in any window shows the
//        same notes.
// Threading: An NSLock serializes configure/save/reset; @Published
//            mutations should be made from the main queue.
// Invariants:
//   - configure(url:) only takes effect on first call
//   - setNote with an empty/whitespace-only string deletes the note
//     rather than storing it
//   - Updating an existing note refreshes its `updated` timestamp
//

import Foundation
import Combine

/// A status note attached to a single tmux session.
public struct SessionNote: Codable, Equatable {
    /// Matches `TmuxSession.id` — `<source.stableKey>:<name>`.
    public let sessionID: String
    /// Short user-supplied text describing the session's current state.
    public var text: String
    /// When the note was last edited; surfaced in the UI as "set Nh ago".
    public var updated: Date

    /// Create a new instance.
    public init(sessionID: String, text: String, updated: Date = Date()) {
        self.sessionID = sessionID
        self.text = text
        self.updated = updated
    }
}

/// Shared store for session status notes. Mirrors the FavoritesStore /
/// NetworkTopologyStore pattern.
public class SessionNotesStore: ObservableObject {
    /// Shared instance.
    public static let shared = SessionNotesStore()

    /// Map of `sessionID → SessionNote`.
    @Published public private(set) var notes: [String: SessionNote] = [:]

    private var url: URL?
    private let lock = NSLock()

    private init() {}

    /// Configure with the on-disk URL. Only takes effect on the first
    /// call (subsequent calls are no-ops, matching the other stores).
    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([String: SessionNote].self, from: data) else { return }
        self.notes = decoded
    }

    private func writeToDisk() {
        guard let url = url else { return }
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: url)
    }

    /// Rewrite stored keys when the keying scheme changes.
    ///
    /// Keeps anything the caller declines to rename, and on a collision
    /// keeps the NEWER note — re-running a migration must never lose the
    /// note someone wrote since.
    public func rekey(_ mapping: [String: String]) {
        guard !mapping.isEmpty else { return }
        lock.lock()
        var moved = notes
        for (old, new) in mapping {
            guard let note = moved.removeValue(forKey: old) else { continue }
            if let existing = moved[new], existing.updated >= note.updated { continue }
            moved[new] = note
        }
        notes = moved
        lock.unlock()
        writeToDisk()
    }

    /// Replace every note at once — what a sync applies after merging.
    ///
    /// A wholesale replacement rather than a series of edits: the merge
    /// already decided the final answer, and applying it note by note
    /// would publish half-merged states to the UI and make deletions
    /// indistinguishable from edits on the way through.
    public func replaceAll(_ incoming: [String: SessionNote]) {
        guard incoming != notes else { return }
        notes = incoming
        lock.lock()
        writeToDisk()
        lock.unlock()
    }

    /// Read the note for a session, if any.
    public func note(for sessionID: String) -> SessionNote? {
        notes[sessionID]
    }

    /// Set (or clear) the note for a session. Empty/whitespace input
    /// deletes the entry rather than storing an empty note.
    public func setNote(_ text: String, for sessionID: String) {
        // Backstop: strip smart-quote/dash substitutions before storing.
        let trimmed = TextSanitizer.sanitize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.removeValue(forKey: sessionID)
        } else {
            notes[sessionID] = SessionNote(sessionID: sessionID, text: trimmed, updated: Date())
        }
        lock.lock()
        writeToDisk()
        lock.unlock()
    }

    /// Remove a note explicitly. Equivalent to `setNote("", for:)` but
    /// reads more clearly at call sites that intend deletion.
    public func clearNote(for sessionID: String) {
        notes.removeValue(forKey: sessionID)
        lock.lock()
        writeToDisk()
        lock.unlock()
    }

    /// Notes that still correspond to a session in `allSessions`,
    /// sorted most-recently-edited first. Sessions that have since been
    /// removed don't appear in the monitor view but the underlying note
    /// is preserved on disk for when the session comes back.
    /// Notes paired with the live sessions they belong to.
    ///
    /// `keys` maps a session to every id it might be STORED under — the
    /// identity key and the legacy in-memory one — so an un-migrated
    /// file, a migrated one, and a half-migrated one all resolve. Default
    /// preserves the old behaviour for callers that have no host list.
    public func activeNotes(in allSessions: [TmuxSession],
                            keys: (TmuxSession) -> [String] = { [$0.id] })
        -> [(session: TmuxSession, note: SessionNote)] {
        var byID: [String: TmuxSession] = [:]
        for session in allSessions {
            for key in keys(session) where byID[key] == nil { byID[key] = session }
        }
        return notes.values
            .compactMap { note in byID[note.sessionID].map { (session: $0, note: note) } }
            .sorted { $0.note.updated > $1.note.updated }
    }

    private func legacyActiveNotes(in allSessions: [TmuxSession]) -> [(session: TmuxSession, note: SessionNote)] {
        // uniquingKeysWith, not uniqueKeysWithValues: the latter TRAPS on a
        // duplicate session id. Duplicates shouldn't happen, but a crash from
        // transient session-list state isn't worth the risk — keep the first.
        let byID = Dictionary(allSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return notes.values
            .compactMap { note in byID[note.sessionID].map { (session: $0, note: note) } }
            .sorted { $0.note.updated > $1.note.updated }
    }

    /// Reset for testing — clears all entries without saving to disk.
    public func reset() {
        lock.lock()
        notes = [:]
        lock.unlock()
    }
}
