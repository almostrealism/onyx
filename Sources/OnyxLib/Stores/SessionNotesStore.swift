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

    /// Read the note for a session, if any.
    public func note(for sessionID: String) -> SessionNote? {
        notes[sessionID]
    }

    /// Set (or clear) the note for a session. Empty/whitespace input
    /// deletes the entry rather than storing an empty note.
    public func setNote(_ text: String, for sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    public func activeNotes(in allSessions: [TmuxSession]) -> [(session: TmuxSession, note: SessionNote)] {
        let byID = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
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
