//
// LabelFilterStore.swift
//
// Responsibility: Which PR labels are worth showing — chosen by name from
//                 the ones the app has actually seen on open PRs.
// Scope: Shared singleton, persisted in UserDefaults like
//        WorkflowFilterStore, whose shape this follows.
//
// Why opt-in: a repo's labels are mostly bookkeeping ("dependencies",
// "size/S", a triage bot's), and the few that matter — what an agent
// thinks of its PR, "needs-human", "ready" — are the user's to name. In
// simple mode a label is only a colored dot, so a dot for every
// bookkeeping label would drown the ones that say something.
//

import Foundation
import Combine

public final class LabelFilterStore: ObservableObject {

    public static let shared = LabelFilterStore()

    /// A label drops off the settings list after this long unseen.
    /// Being included keeps it listed regardless.
    public static let memory: TimeInterval = 30 * 86400

    private let defaults: UserDefaults
    private static let seenKey = "pr_labels_seen"
    private static let colorsKey = "pr_labels_colors"
    private static let includedKey = "pr_labels_included"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Label name → when an open PR last carried it.
    public var seen: [String: Date] {
        get {
            let raw = defaults.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: Self.seenKey)
            objectWillChange.send()
        }
    }

    /// Label name → the color it last had, for the settings list. A PR
    /// shows its own label's color; two repos can color one name apart.
    public var colors: [String: String] {
        get { defaults.dictionary(forKey: Self.colorsKey) as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: Self.colorsKey)
            objectWillChange.send()
        }
    }

    /// Names the user has switched on. Empty by default: see the header.
    public var included: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.includedKey) ?? []) }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Self.includedKey)
            objectWillChange.send()
            includedChanged.send()
        }
    }

    /// Fires when the CHOICE changes, not when a label is merely seen —
    /// shared-state sync listens here (see WorkflowFilterStore).
    public let includedChanged = PassthroughSubject<Void, Never>()

    /// The choice as it travels in shared state.
    public var includedList: [String] { included.sorted() }

    public func isIncluded(_ name: String) -> Bool { included.contains(name) }

    public func setIncluded(_ name: String, _ on: Bool) {
        var set = included
        if on { set.insert(name) } else { set.remove(name) }
        included = set
    }

    /// The PR's labels the user asked to see, in the PR's order.
    public func shown(_ pr: PullRequest) -> [PRLabel] {
        let keep = included
        guard !keep.isEmpty else { return [] }
        return pr.labels.filter { keep.contains($0.name) }
    }

    /// Record the labels on these PRs. Called by the forge managers after
    /// every poll — filtering happens on the way OUT, so a label the user
    /// hasn't opted into is still offered to them.
    public func noteSeen(_ labels: [PRLabel], at now: Date = Date()) {
        var map = seen
        var hues = colors
        for label in labels where !label.name.isEmpty {
            map[label.name] = now
            hues[label.name] = label.colorHex
        }
        let keep = included
        map = map.filter { keep.contains($0.key) || now.timeIntervalSince($0.value) < Self.memory }
        hues = hues.filter { map[$0.key] != nil }
        if map != seen { seen = map }
        if hues != colors { colors = hues }
    }

    /// What the settings list offers: everything seen recently, plus
    /// anything included (even if no open PR carries it now), by name.
    public func offered(now: Date = Date()) -> [String] {
        let recent = seen.filter { now.timeIntervalSince($0.value) < Self.memory }.map(\.key)
        return Array(Set(recent).union(included))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func resetForTesting() {
        defaults.removeObject(forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.colorsKey)
        defaults.removeObject(forKey: Self.includedKey)
        objectWillChange.send()
    }
}
