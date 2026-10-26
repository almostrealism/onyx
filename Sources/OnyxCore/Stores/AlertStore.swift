//
// AlertStore.swift
//
// Responsibility: Keeps the alerts agents have sent, per session, and
//                 whether each session has unseen ones. Persists, so the
//                 history survives a restart — an alert you were away
//                 for is exactly the one worth keeping.
// Scope: Shared singleton.
// Threading: NSLock around the map; @Published writes on main.
//
// Capped per session and overall: an agent in a loop must not be able to
// grow this without bound, and the hundredth copy of a message is worth
// nothing next to the first.
//

import Foundation

public final class AlertStore: ObservableObject {
    public static let shared = AlertStore()

    /// Newest first, per session key. Alerts with no session live under
    /// `unattachedKey`.
    @Published public private(set) var alerts: [String: [SessionAlert]] = [:]

    public static let unattachedKey = "-"
    /// Per session. Enough to see what happened while you were away,
    /// bounded so a runaway agent can't fill the disk.
    public static let maxPerSession = 50

    private var url: URL?
    private let lock = NSLock()

    private init() {}

    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [SessionAlert]].self, from: data) {
            alerts = decoded
        }
    }

    private func writeToDisk() {
        guard let url, let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: url)
    }

    // MARK: - Reading

    public func alerts(for key: String?) -> [SessionAlert] {
        alerts[key ?? Self.unattachedKey] ?? []
    }

    /// Whether a session has alerts the user hasn't looked at. This is
    /// what lights the indicator.
    public func hasUnseen(for key: String?) -> Bool {
        alerts(for: key).contains { !$0.seen }
    }

    public func unseenCount(for key: String?) -> Int {
        alerts(for: key).filter { !$0.seen }.count
    }

    /// Every session currently showing an indicator.
    public var keysWithUnseen: [String] {
        alerts.compactMap { key, list in list.contains(where: { !$0.seen }) ? key : nil }
    }

    // MARK: - Writing

    public func record(_ alert: SessionAlert) {
        onMain {
            let key = alert.sessionKey ?? Self.unattachedKey
            var list = self.alerts[key] ?? []
            list.insert(alert, at: 0)
            if list.count > Self.maxPerSession { list.removeLast(list.count - Self.maxPerSession) }
            self.alerts[key] = list
            self.writeToDisk()
        }
    }

    /// Mark a session's alerts as seen — the indicator goes out and can
    /// light again on the next one. The history stays: "clear" means
    /// "I've looked", not "throw it away".
    public func markSeen(for key: String?) {
        onMain {
            let k = key ?? Self.unattachedKey
            guard var list = self.alerts[k], list.contains(where: { !$0.seen }) else { return }
            for i in list.indices { list[i].seen = true }
            self.alerts[k] = list
            self.writeToDisk()
        }
    }

    /// Forget a session's alerts entirely — used when the session itself
    /// is killed, so a dead session doesn't keep history nobody can
    /// reach.
    public func forget(key: String) {
        onMain {
            guard self.alerts[key] != nil else { return }
            self.alerts[key] = nil
            self.writeToDisk()
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    public func resetForTesting() {
        alerts = [:]
        url = nil
    }
}
