//
// SharedState.swift
//
// Responsibility: The bundle of state that can live on a remote host so
//                 every Mac running Onyx sees the same thing — session
//                 notes and favorites — and the rules for merging two
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
    /// Favorite sessions, in the order they're shown.
    public var favorites: [FavoriteEntry]
    /// Tracked pipeline URLs, verbatim as the user gave them, per forge.
    ///
    /// The URLs travel; the TOKENS never do. A personal access token is a
    /// credential for one person on one machine, and putting one in a
    /// file on a shared host — to save typing it twice — is not a trade
    /// this feature gets to make on the user's behalf.
    public var githubPipelines: [String]
    public var gitlabPipelines: [String]
    /// Workflow names the user has switched on under open PRs (see
    /// WorkflowFilterStore). A choice about the work, not the desk, so
    /// it follows the user between machines the way tracked pipelines
    /// do. Sorted, so two copies with the same choice compare equal.
    public var prWorkflows: [String]
    /// When this copy was written, for the status line.
    public var updated: Date
    /// Which Mac wrote it, so the status line can say "last written by
    /// laptop" when two machines are sharing.
    public var writtenBy: String
    /// Every Mac's hosts, for the iPad (docs/ios-plan.md): HostConfig with
    /// the per-machine key path blanked. A Mac contributes its hosts and
    /// never adopts another's — its host list is its own.
    public var hosts: [HostConfig]
    /// The settings that follow the user (`SharedSetting`), by name, as
    /// JSON — so a setting a newer Onyx added survives an older one's
    /// merge.
    public var settings: [String: JSONValue]
    /// Top-level fields this build doesn't know, kept verbatim and written
    /// back. An older Onyx that dropped them would delete a newer one's
    /// data every time it synced.
    public var unknownFields: [String: JSONValue]

    public init(notes: [String: SessionNote] = [:],
                favorites: [FavoriteEntry] = [],
                githubPipelines: [String] = [],
                gitlabPipelines: [String] = [],
                prWorkflows: [String] = [],
                updated: Date = Date(),
                writtenBy: String = "",
                hosts: [HostConfig] = [],
                settings: [String: JSONValue] = [:],
                unknownFields: [String: JSONValue] = [:]) {
        self.notes = notes
        self.favorites = favorites
        self.githubPipelines = githubPipelines
        self.gitlabPipelines = gitlabPipelines
        self.prWorkflows = prWorkflows.sorted()
        self.updated = updated
        self.writtenBy = writtenBy
        self.hosts = hosts
        self.settings = settings
        self.unknownFields = unknownFields
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
        prWorkflows = (try c.decodeIfPresent([String].self, forKey: .prWorkflows) ?? []).sorted()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        writtenBy = try c.decodeIfPresent(String.self, forKey: .writtenBy) ?? ""
        hosts = (try? c.decodeIfPresent([HostConfig].self, forKey: .hosts)) ?? []
        settings = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .settings)) ?? [:]

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let all = try decoder.container(keyedBy: AnyCodingKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in all.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    public func encode(to encoder: Encoder) throws {
        // Unknown fields first, so a known one of the same name can never
        // be shadowed by a stale copy.
        var all = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in unknownFields {
            try all.encode(value, forKey: AnyCodingKey(key))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notes, forKey: .notes)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(githubPipelines, forKey: .githubPipelines)
        try c.encode(gitlabPipelines, forKey: .gitlabPipelines)
        try c.encode(prWorkflows, forKey: .prWorkflows)
        try c.encode(updated, forKey: .updated)
        try c.encode(writtenBy, forKey: .writtenBy)
        try c.encode(hosts, forKey: .hosts)
        try c.encode(settings, forKey: .settings)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case notes, favorites, githubPipelines, gitlabPipelines, prWorkflows, updated, writtenBy
        case hosts, settings
    }

    public static let empty = SharedState(updated: .distantPast)

    /// Nothing in it at all — of the user's own content.
    ///
    /// Hosts and settings don't count: every Mac always has some, so
    /// counting them would mean this was never true, and the refusal it
    /// powers would never fire on the notes it exists to protect.
    ///
    /// The shape of the disaster this guards: a copy with zero of
    /// everything is never a legitimate destination once anything existed.
    /// It means something upstream failed and produced an absence, and
    /// absence is what a three-way merge reads as "the other side deleted
    /// it all".
    public var isEmpty: Bool {
        notes.isEmpty && favorites.isEmpty
            && githubPipelines.isEmpty && gitlabPipelines.isEmpty
            && prWorkflows.isEmpty
    }

    /// Whether two copies carry the same content. Deliberately ignores
    /// `updated` and `writtenBy`: a push whose only difference is the
    /// timestamp is a push that does nothing but cost a round trip, and
    /// two Macs doing it to each other would never settle.
    public func sameContent(as other: SharedState) -> Bool {
        notes == other.notes && favorites == other.favorites
            && githubPipelines == other.githubPipelines
            && gitlabPipelines == other.gitlabPipelines
            && prWorkflows == other.prWorkflows
            && hosts == other.hosts && settings == other.settings
            && unknownFields == other.unknownFields
    }
}

public enum SharedStateMerge {

    /// Combine two copies of the shared state.
    ///
    /// `base` is what we last saw at both ends. With it, a value missing
    /// from one side is a DELETION and is honored. Without it, nothing is
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
            prWorkflows: mergeNames(base: base?.prWorkflows,
                                    local: local.prWorkflows,
                                    remote: remote.prWorkflows),
            updated: Date(),
            writtenBy: local.writtenBy,
            hosts: mergeHosts(base: base?.hosts, local: local.hosts, remote: remote.hosts),
            settings: mergeValues(base: base?.settings, local: local.settings, remote: remote.settings,
                                  withoutShadowPrefer: .remote),
            // Kept, never decided: whatever a newer Onyx wrote, the newest
            // copy of it — the host's — wins.
            unknownFields: local.unknownFields.merging(remote.unknownFields) { _, theirs in theirs })
    }

    // MARK: - Values by key (settings, hosts)

    enum Side { case local, remote }

    /// Three-way per key. A side unchanged since the shadow takes the
    /// other's value — a deletion included; both changed, local wins (and
    /// the next sync carries it everywhere). With no shadow nothing is
    /// deleted, and a disagreement goes to `withoutShadowPrefer`: settings
    /// prefer the host's, because a new device's settings are only its
    /// defaults, and adopting them would reset every other device.
    static func mergeValues<V: Equatable>(base: [String: V]?, local: [String: V],
                                          remote: [String: V],
                                          withoutShadowPrefer: Side = .local) -> [String: V] {
        var result: [String: V] = [:]
        for key in Set(local.keys).union(remote.keys).union(base?.keys ?? [:].keys) {
            let l = local[key], r = remote[key], b = base?[key]
            if l == r { if let l { result[key] = l }; continue }
            guard base != nil else {
                let value = withoutShadowPrefer == .local ? (l ?? r) : (r ?? l)
                if let value { result[key] = value }
                continue
            }
            if l == b { if let r { result[key] = r }; continue }
            if r == b { if let l { result[key] = l }; continue }
            // Both changed: an edit beats a deletion, then local wins.
            if let value = l ?? r { result[key] = value }
        }
        return result
    }

    /// Hosts by id, with the same rules; local order first.
    static func mergeHosts(base: [HostConfig]?, local: [HostConfig], remote: [HostConfig]) -> [HostConfig] {
        func keyed(_ hosts: [HostConfig]) -> [String: HostConfig] {
            Dictionary(hosts.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        }
        let merged = mergeValues(base: base.map(keyed), local: keyed(local), remote: keyed(remote))
        var order = local.map(\.id.uuidString)
        for host in remote where !order.contains(host.id.uuidString) { order.append(host.id.uuidString) }
        return order.compactMap { merged[$0] }
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

    /// Same membership rules as favorites, matched on the PARSED id
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

    // MARK: - PR workflow choices

    /// Plain set membership with the same rules as favorites: both have
    /// it → keep; one has it and there's no shadow → keep (an addition);
    /// one has it and the shadow had it → the other side switched it
    /// off. Sorted, because order carries no meaning here.
    static func mergeNames(base: [String]?, local: [String], remote: [String]) -> [String] {
        let l = Set(local), r = Set(remote), b = base.map(Set.init)
        return l.union(r).filter { name in
            if l.contains(name) && r.contains(name) { return true }
            guard let b else { return true }
            return !b.contains(name)
        }.sorted()
    }

    // MARK: - Favorites

    /// Membership is merged; PLACEMENT is not.
    ///
    /// `windows` says which of this Mac's four windows shows a favorite,
    /// which is a fact about one desk and not about the work. So a
    /// favorite both sides know keeps the local placement, and only the
    /// list of what's favorited is shared.
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
