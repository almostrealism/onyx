//
// PageWatchStore.swift
//
// Responsibility: Owns the user's page watches and what each has seen.
//                 Persists to JSON so a watch survives a restart — these
//                 run for weeks, and the previous observation IS the
//                 feature.
// Scope: Shared singleton (PageWatchStore.shared).
// Threading: NSLock around mutation; @Published writes on main.
// Invariants:
//   - configure(url:) only takes effect on the first call
//   - a watch's state travels with it; deleting a watch deletes its state
//   - saving is synchronous and small (a handful of entries)
//

import Foundation

public class PageWatchStore: ObservableObject {
    public static let shared = PageWatchStore()

    @Published public private(set) var entries: [WatchEntry] = []

    private var url: URL?
    private let lock = NSLock()

    private init() {}

    /// Configure with the on-disk URL. First call wins, matching the
    /// other stores.
    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([WatchEntry].self, from: data) {
            entries = decoded
        }
    }

    private func writeToDisk() {
        guard let url = url, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url)
    }

    // MARK: - Mutation

    public func add(_ watch: PageWatch) {
        onMain {
            self.entries.append(WatchEntry(watch: watch))
            self.writeToDisk()
        }
    }

    public func update(_ watch: PageWatch) {
        onMain {
            guard let i = self.entries.firstIndex(where: { $0.id == watch.id }) else { return }
            // State is deliberately preserved across an edit EXCEPT when
            // what's being looked for changes — a baseline established
            // against different text says nothing about the new text, and
            // keeping it would fire (or fail to fire) on the next check
            // for no reason the user could follow.
            let old = self.entries[i].watch
            let sameQuestion = old.text == watch.text && old.trigger == watch.trigger
                && old.url == watch.url
            self.entries[i] = WatchEntry(watch: watch,
                                         state: sameQuestion ? self.entries[i].state : WatchState())
            self.writeToDisk()
        }
    }

    public func remove(_ id: UUID) {
        onMain {
            self.entries.removeAll { $0.id == id }
            self.writeToDisk()
        }
    }

    /// Record the result of a check.
    public func setState(_ state: WatchState, for id: UUID) {
        onMain {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[i].state = state
            self.writeToDisk()
        }
    }

    /// Clear the "this fired" flag once the user has seen it, leaving the
    /// watch armed for the next transition.
    public func acknowledge(_ id: UUID) {
        onMain {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            self.entries[i].state.firedAt = nil
            self.writeToDisk()
        }
    }

    /// Watches currently holding unacknowledged news.
    public var fired: [WatchEntry] {
        entries.filter { $0.state.firedAt != nil }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    public func resetForTesting() {
        entries = []
        url = nil
    }
}
