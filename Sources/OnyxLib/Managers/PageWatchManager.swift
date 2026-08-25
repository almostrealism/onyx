//
// PageWatchManager.swift
//
// Responsibility: Polls each enabled watch on its own cadence, decides
//                 whether the condition was met, and records the result.
//                 Surfaces a fired watch through DiagnosticLog and (when
//                 the app is a real bundle) a system notification.
// Scope: Shared singleton — one poller per process regardless of how many
//        windows are open, like the other network pollers.
// Threading: Timer on main; fetches on URLSession; results back to main
//            before touching the store.
// Invariants:
//   - a watch is never checked more often than its interval, and never
//     more often than PageWatch.minimumInterval
//   - one in-flight request per watch; a slow response skips the tick
//     rather than stacking
//   - the first check of a watch establishes a baseline and cannot fire
//

import Foundation
import CryptoKit
#if canImport(UserNotifications)
import UserNotifications
#endif

public final class PageWatchManager {
    public static let shared = PageWatchManager()

    /// How often we consider whether anything is due. Each watch has its
    /// own interval; this is just the heartbeat that checks the clock.
    private static let tickInterval: TimeInterval = 60

    /// Wall-clock cap on one fetch. These are big commercial pages; a
    /// slow one shouldn't hold a slot until the next tick.
    private static let requestTimeout: TimeInterval = 20

    private var timer: Timer?
    private var inFlight: Set<UUID> = []
    private let lock = NSLock()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        // Never serve a watch from cache: a cached body would look like
        // "no change" forever, which is the one answer this must never
        // give wrongly.
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil, NSClassFromString("XCTest") == nil else { return }
        requestNotificationPermissionIfPossible()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // One pass now so a watch created before a restart doesn't wait a
        // minute to resume.
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func tick() {
        let now = Date()
        for entry in PageWatchStore.shared.entries where entry.watch.isRunnable {
            let interval = TimeInterval(max(PageWatch.minimumInterval,
                                            entry.watch.intervalMinutes)) * 60
            if let last = entry.state.lastCheck, now.timeIntervalSince(last) < interval { continue }

            lock.lock()
            let busy = inFlight.contains(entry.id)
            if !busy { inFlight.insert(entry.id) }
            lock.unlock()
            guard !busy else { continue }

            check(entry)
        }
    }

    /// Check one watch now, regardless of when it last ran. Used by the
    /// "check now" button, which exists so a user can tell the difference
    /// between "armed" and "broken" without waiting a quarter of an hour.
    public func checkNow(_ id: UUID) {
        guard let entry = PageWatchStore.shared.entries.first(where: { $0.id == id }) else { return }
        lock.lock()
        let busy = inFlight.contains(id)
        if !busy { inFlight.insert(id) }
        lock.unlock()
        guard !busy else { return }
        check(entry)
    }

    private func check(_ entry: WatchEntry) {
        guard let url = URL(string: entry.watch.url) else {
            finish(entry, state: failed(entry, "That isn't a URL Onyx can fetch."))
            return
        }

        var req = URLRequest(url: url)
        // Identify as a browser. Several storefronts serve a stub to
        // anything that doesn't, and a stub has neither the notice we're
        // watching for nor any sign that it's missing.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.finish(entry, state: self.failed(entry, error.localizedDescription))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                // Say which code. "403" and "404" mean completely
                // different things to whoever has to fix the watch.
                self.finish(entry, state: self.failed(
                    entry, "HTTP \(http.statusCode) from \(url.host ?? "the server")"))
                return
            }
            guard let data, !data.isEmpty else {
                self.finish(entry, state: self.failed(entry, "Empty response."))
                return
            }

            let body = String(decoding: data, as: UTF8.self)
            let present = body.range(of: entry.watch.text,
                                     options: [.caseInsensitive]) != nil
            let hash = Self.hash(data)

            var state = entry.state
            let fires = state.evaluate(trigger: entry.watch.trigger,
                                       present: present, hash: hash)
            state.present = present
            state.hash = hash
            state.lastCheck = Date()
            state.lastError = nil
            if fires { state.firedAt = Date() }

            self.finish(entry, state: state, fired: fires)
        }.resume()
    }

    private func failed(_ entry: WatchEntry, _ message: String) -> WatchState {
        var state = entry.state
        state.lastCheck = Date()
        state.lastError = message
        // Deliberately does NOT touch `present`/`hash`: a failed check is
        // not an observation, and letting it clear the baseline would
        // make the next success look like a transition.
        return state
    }

    private func finish(_ entry: WatchEntry, state: WatchState, fired: Bool = false) {
        lock.lock(); inFlight.remove(entry.id); lock.unlock()
        DispatchQueue.main.async {
            PageWatchStore.shared.setState(state, for: entry.id)
            if fired {
                DiagnosticLog.shared.record(
                    "watch", "\(entry.watch.label) — \(entry.watch.trigger.label)")
                self.notify(entry.watch)
            } else if let err = state.lastError {
                DiagnosticLog.shared.record("watch", "\(entry.watch.label): \(err)",
                                            failure: true)
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Notification

    /// UNUserNotificationCenter needs a real bundle; under `swift run`
    /// there isn't one and touching it traps. Everything here is
    /// therefore gated on a bundle identifier existing, and the in-app
    /// banner is the path that always works.
    private var canUseSystemNotifications: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermissionIfPossible() {
        #if canImport(UserNotifications)
        guard canUseSystemNotifications else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    private func notify(_ watch: PageWatch) {
        #if canImport(UserNotifications)
        guard canUseSystemNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = watch.label
        content.body = watch.trigger == .disappears
            ? "The text you were waiting to lose is gone from the page."
            : "The page changed the way you were waiting for."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: watch.id.uuidString,
                                  content: content, trigger: nil))
        #endif
    }
}
