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
    /// Tracked pipeline URLs, verbatim as the user gave them, per forge.
    ///
    /// The URLs travel; the TOKENS never do. A personal access token is a
    /// credential for one person on one machine, and putting one in a
    /// file on a shared host — to save typing it twice — is not a trade
    /// this feature gets to make on the user's behalf.
    public var githubPipelines: [String]
    public var gitlabPipelines: [String]
    /// When this copy was written, for the status line.
    public var updated: Date
    /// Which Mac wrote it, so the status line can say "last written by
    /// laptop" when two machines are sharing.
    public var writtenBy: String

    public init(notes: [String: SessionNote] = [:],
                favorites: [FavoriteEntry] = [],
                githubPipelines: [String] = [],
                gitlabPipelines: [String] = [],
                updated: Date = Date(),
                writtenBy: String = "") {
        self.notes = notes
        self.favorites = favorites
        self.githubPipelines = githubPipelines
        self.gitlabPipelines = gitlabPipelines
        self.updated = updated
        self.writtenBy = writtenBy
    }

    /// Decoded field by field, every one optional.
    ///
    /// The synthesized decoder REQUIRES every key, default values and
    /// all — so adding a field would make this type fail to decode any
    /// file written before it existed. That failure is not cosmetic: the
    /// sync refuses to overwrite a copy it cannot read, so one new field
    /// would stop two machines syncing until someone deleted the file by
    /// hand. Adding a field here must stay free.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notes = try c.decodeIfPresent([String: SessionNote].self, forKey: .notes) ?? [:]
        favorites = try c.decodeIfPresent([FavoriteEntry].self, forKey: .favorites) ?? []
        githubPipelines = try c.decodeIfPresent([String].self, forKey: .githubPipelines) ?? []
        gitlabPipelines = try c.decodeIfPresent([String].self, forKey: .gitlabPipelines) ?? []
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        writtenBy = try c.decodeIfPresent(String.self, forKey: .writtenBy) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case notes, favorites, githubPipelines, gitlabPipelines, updated, writtenBy
    }

    public static let empty = SharedState(updated: .distantPast)

    /// Whether two copies carry the same content. Deliberately ignores
    /// `updated` and `writtenBy`: a push whose only difference is the
    /// timestamp is a push that does nothing but cost a round trip, and
    /// two Macs doing it to each other would never settle.
    public func sameContent(as other: SharedState) -> Bool {
        notes == other.notes && favorites == other.favorites
            && githubPipelines == other.githubPipelines
            && gitlabPipelines == other.gitlabPipelines
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
            githubPipelines: mergePipelines(base: base?.githubPipelines,
                                            local: local.githubPipelines,
                                            remote: remote.githubPipelines),
            gitlabPipelines: mergePipelines(base: base?.gitlabPipelines,
                                            local: local.gitlabPipelines,
                                            remote: remote.gitlabPipelines),
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
                if let l, let r {
                    result[key] = l.updated >= r.updated ? l : r
                } else if let value = l ?? r {
                    result[key] = value
                }
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

    // MARK: - Tracked pipelines

    /// Same membership rules as favourites, matched on the PARSED id
    /// rather than the URL text.
    ///
    /// One pipeline has several spellings — a workflow page, a run page,
    /// with or without a query string — and two machines that added the
    /// same pipeline by different routes must end up with one entry, not
    /// two that produce colliding ids downstream. The local spelling wins
    /// because it is the one the user here typed.
    static func mergePipelines(base: [String]?,
                               local: [String],
                               remote: [String]) -> [String] {
        func id(_ url: String) -> String { PipelineSpec.parse(url)?.id ?? url }

        let localIDs = Set(local.map(id))
        let remoteIDs = Set(remote.map(id))
        let baseIDs = base.map { Set($0.map(id)) }

        func keep(_ key: String) -> Bool {
            if localIDs.contains(key) && remoteIDs.contains(key) { return true }
            guard let baseIDs else { return true }   // no shadow: never remove
            return !baseIDs.contains(key)
        }

        var seen = Set<String>()
        var result = local.filter { seen.insert(id($0)).inserted && keep(id($0)) }
        for url in remote where !localIDs.contains(id(url)) && keep(id(url)) {
            if seen.insert(id(url)).inserted { result.append(url) }
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
