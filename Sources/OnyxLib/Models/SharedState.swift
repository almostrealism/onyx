//
// SharedState.swift
//
// Responsibility: The bundle of state that can live on a remote host so
//                 every Mac running Onyx sees the same thing — session
//                 notes and favourites — and the rules for merging two
//                 copies of it.
// Scope: Model. Pure data and pure functions; no I/O, no SSH, no stores.
//        The merge is the part that can lose a user's work, so it is
//        written where it can be tested exhaustively.
//
// The merge is three-way, against a SHADOW of what we last synced. That
// is the only way to tell "I deleted this note" from "I have never seen
// this note" — and getting those two confused is how a sync either
// resurrects deleted notes forever or silently deletes other machines'.
//
// Where the shadow is missing (the first sync against a host, or the
// moment the user MOVES their home host), the merge falls back to a union
// and applies no deletions at all. Adopting a new home must not be able
// to delete anything: the user asked to combine two sets, not to have one
// win. A resurrected note is an annoyance; a lost one is the bug that
// makes someone stop trusting the feature.
//

import Foundation

public struct SharedState: Codable, Equatable {
    /// storage key → note.
    public var notes: [String: SessionNote]
    /// Favourite sessions, in the order they're shown.
    public var favorites: [FavoriteEntry]
    /// When this copy was written, for the status line.
    public var updated: Date
    /// Which Mac wrote it, so the status line can say "last written by
    /// laptop" when two machines are sharing.
    public var writtenBy: String

    public init(notes: [String: SessionNote] = [:],
                favorites: [FavoriteEntry] = [],
                updated: Date = Date(),
                writtenBy: String = "") {
        self.notes = notes
        self.favorites = favorites
        self.updated = updated
        self.writtenBy = writtenBy
    }

    public static let empty = SharedState(updated: .distantPast)

    /// Whether two copies carry the same content. Deliberately ignores
    /// `updated` and `writtenBy`: a push whose only difference is the
    /// timestamp is a push that does nothing but cost a round trip, and
    /// two Macs doing it to each other would never settle.
    public func sameContent(as other: SharedState) -> Bool {
        notes == other.notes && favorites == other.favorites
    }
}

public enum SharedStateMerge {

    /// Combine two copies of the shared state.
    ///
    /// `base` is what we last saw at both ends. With it, a value missing
    /// from one side is a DELETION and is honoured. Without it, nothing is
    /// deleted — see the file comment.
    public static func merge(base: SharedState?,
                             local: SharedState,
                             remote: SharedState) -> SharedState {
        SharedState(
            notes: mergeNotes(base: base?.notes, local: local.notes, remote: remote.notes),
            favorites: mergeFavorites(base: base?.favorites,
                                      local: local.favorites,
                                      remote: remote.favorites),
            updated: Date(),
            writtenBy: local.writtenBy)
    }

    // MARK: - Notes

    static func mergeNotes(base: [String: SessionNote]?,
                           local: [String: SessionNote],
                           remote: [String: SessionNote]) -> [String: SessionNote] {
        var result: [String: SessionNote] = [:]
        for key in Set(local.keys).union(remote.keys).union(base?.keys ?? [:].keys) {
            let l = local[key], r = remote[key], b = base?[key]

            // Agreement needs no rule.
            if l == r {
                if let value = l { result[key] = value }
                continue
            }

            guard base != nil else {
                // No shadow: union. Both present → the newer edit; one
                // present → that one. Never a deletion.
                if let l, let r { result[key] = l.updated >= r.updated ? l : r }
                else if let value = l ?? r { result[key] = value }
                continue
            }

            // One side is unchanged since the shadow, so the other side's
            // change — including a deletion — is the answer.
            if l == b {
                if let r { result[key] = r }
                continue
            }
            if r == b {
                if let l { result[key] = l }
                continue
            }

            // Both changed. An edit beats a deletion: someone wrote those
            // words on purpose, and getting them back after a sync is
            // impossible, while deleting again takes one keystroke.
            switch (l, r) {
            case (.some(let l), .some(let r)): result[key] = l.updated >= r.updated ? l : r
            case (.some(let l), .none):        result[key] = l
            case (.none, .some(let r)):        result[key] = r
            case (.none, .none):               break
            }
        }
        return result
    }

    // MARK: - Favourites

    /// Membership is merged; PLACEMENT is not.
    ///
    /// `windows` says which of this Mac's four windows shows a favourite,
    /// which is a fact about one desk and not about the work. So a
    /// favourite both sides know keeps the local placement, and only the
    /// list of what's favourited is shared.
    static func mergeFavorites(base: [FavoriteEntry]?,
                               local: [FavoriteEntry],
                               remote: [FavoriteEntry]) -> [FavoriteEntry] {
        let localIDs = Set(local.map(\.sessionID))
        let remoteIDs = Set(remote.map(\.sessionID))
        let baseIDs = base.map { Set($0.map(\.sessionID)) }

        func keep(_ id: String) -> Bool {
            if localIDs.contains(id) && remoteIDs.contains(id) { return true }
            // Only one side has it. With no shadow that's an addition, so
            // keep it; with one, "in the shadow and gone from one side"
            // is a removal.
            guard let baseIDs else { return true }
            return !baseIDs.contains(id)
        }

        // Local order first — the user arranged that — then whatever the
        // other machine added, in its own order.
        var result = local.filter { keep($0.sessionID) }
        for entry in remote where !localIDs.contains(entry.sessionID) && keep(entry.sessionID) {
            result.append(entry)
        }
        return result
    }
}
