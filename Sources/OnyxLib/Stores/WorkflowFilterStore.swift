//
// WorkflowFilterStore.swift
//
// Responsibility: Which workflows are worth showing under an open PR —
//                 chosen by name from the ones the app has actually seen.
// Scope: Shared singleton, persisted in UserDefaults like the forge
//        config stores.
//
// Why opt-in: a project's PRs run every workflow the repo has, and most
// of them ("Running Copilot Code Review", a labeler, a stale-bot) gate
// nothing. The one that gates the merge is usually one, sometimes none.
// So nothing is shown until the user says which — and rather than make
// them type a name, the app remembers every workflow it has seen on a
// PR and offers the list.
//

import Foundation
import Combine

public final class WorkflowFilterStore: ObservableObject {

    public static let shared = WorkflowFilterStore()

    /// A name drops off the settings list after this long unseen —
    /// a workflow that was deleted last spring shouldn't be offered
    /// forever. Being included keeps it listed regardless.
    public static let memory: TimeInterval = 30 * 86400

    private let defaults: UserDefaults
    private static let seenKey = "pr_workflows_seen"
    private static let includedKey = "pr_workflows_included"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Workflow name → when a PR last had a run of it.
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

    /// Names the user has switched on. Empty by default: see the header.
    public var included: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.includedKey) ?? []) }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Self.includedKey)
            objectWillChange.send()
        }
    }

    public func isIncluded(_ name: String) -> Bool { included.contains(name) }

    public func setIncluded(_ name: String, _ on: Bool) {
        var set = included
        if on { set.insert(name) } else { set.remove(name) }
        included = set
    }

    /// Whether a run belongs under its PR.
    public func keeps(_ run: PRPipelineRun) -> Bool { included.contains(run.name) }

    /// Record that these workflows exist. Called by the monitor after
    /// every fetch, with every name it found — filtering happens on
    /// the way OUT, so a workflow the user hasn't opted into is still
    /// offered to them.
    public func noteSeen(_ names: [String], at now: Date = Date()) {
        guard !names.isEmpty else { return }
        var map = seen
        for name in names where !name.isEmpty { map[name] = now }
        // Prune while we're here, so the list can't grow without bound.
        let keep = included
        map = map.filter { keep.contains($0.key) || now.timeIntervalSince($0.value) < Self.memory }
        if map != seen { seen = map }
    }

    /// What the settings list offers: everything seen recently, plus
    /// anything included (even if it hasn't run lately), by name.
    public func offered(now: Date = Date()) -> [String] {
        let recent = seen.filter { now.timeIntervalSince($0.value) < Self.memory }.map(\.key)
        return Array(Set(recent).union(included))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func resetForTesting() {
        defaults.removeObject(forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.includedKey)
        objectWillChange.send()
    }
}
