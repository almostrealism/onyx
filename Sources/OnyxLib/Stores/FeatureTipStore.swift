//
// FeatureTipStore.swift
//
// Responsibility: What this person has been shown of FeatureCatalog —
//                 which features What's New has announced, which tips are
//                 done with (used, or closed).
// Scope: Store — shared by every window, so closing a tip in one closes
//        it in all; kept in UserDefaults on this Mac.
//

import Foundation

public final class FeatureTipStore: ObservableObject {

    public static let shared = FeatureTipStore()

    @Published public private(set) var announced: Set<String>
    @Published public private(set) var retired: Set<String>

    private let defaults: UserDefaults
    static let announcedKey = "featuresAnnounced"
    static let retiredKey = "featureTipsRetired"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        announced = Set(defaults.stringArray(forKey: Self.announcedKey) ?? [])
        retired = Set(defaults.stringArray(forKey: Self.retiredKey) ?? [])
    }

    public var unannounced: [Feature] { FeatureCatalog.unannounced(announced: announced) }

    public func tip(at place: FeaturePlace) -> Feature? {
        FeatureCatalog.tip(at: place, retired: retired)
    }

    /// The feature was used: its tip has done its job. Safe to call on
    /// every use — and from any thread.
    public func used(_ id: String) {
        onMain { self.retire(id) }
    }

    /// The person closed the tip.
    public func dismissTip(_ id: String) {
        onMain { self.retire(id) }
    }

    /// What's New was shown (and closed) for these.
    public func markAnnounced(_ ids: [String]) {
        onMain {
            let new = self.announced.union(ids)
            guard new != self.announced else { return }
            self.announced = new
            self.defaults.set(Array(new).sorted(), forKey: Self.announcedKey)
        }
    }

    /// A new user gets the tour, not a list of what changed in a release
    /// they never had: everything that exists now counts as announced.
    /// Tips still show — they teach the feature where it's used.
    public func markAllAnnounced() {
        markAnnounced(FeatureCatalog.all.map(\.id))
    }

    private func retire(_ id: String) {
        guard !retired.contains(id) else { return }
        retired.insert(id)
        defaults.set(Array(retired).sorted(), forKey: Self.retiredKey)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
