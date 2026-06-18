//
// TerminalActivityStore.swift
//
// Responsibility: Tracks when each session's terminal last *meaningfully*
//                 changed, so the monitor overlay can show how long a
//                 session has been quiet — a quick "still working or gone
//                 idle?" signal for sessions running tests etc.
// Scope: Shared singleton.
// Threading: lock-guarded map; UI invalidations coalesced to ~1 Hz on main.
//
// Why content hashing rather than raw bytes: the terminal receives output
// constantly that ISN'T real program activity — tmux redraws its status
// bar (with a ticking clock) every minute, and a reconnect repaints the
// whole pane. Stamping on bytes made the idle clock reset every 60s and on
// every reconnect. Instead the OnyxTerminalView poller reports a hash of
// the visible pane (minus the status-bar row); the clock only advances when
// that hash actually changes.
//

import Foundation
import Combine

public final class TerminalActivityStore: ObservableObject {

    public static let shared = TerminalActivityStore()

    private let lock = NSLock()
    private var lastChange: [String: Date] = [:]
    private var lastHash: [String: Int] = [:]
    /// Content reported before this instant is ignored for a session —
    /// used to drop the tmux re-attach redraw burst right after a reconnect.
    private var suppressUntil: [String: Date] = [:]
    private var publishScheduled = false

    private init() {}

    /// Report the session's current meaningful terminal content (the visible
    /// pane with the status-bar row excluded — the caller handles that). The
    /// idle clock advances only when the hash differs from the last report,
    /// so a status-bar clock tick or a redraw of identical content doesn't
    /// count. The first report for a session seeds the clock.
    public func recordContent(sessionID: String, contentHash: Int) {
        let now = Date()
        lock.lock()
        if let until = suppressUntil[sessionID], now < until { lock.unlock(); return }
        let changed = lastHash[sessionID] != contentHash
        if changed {
            lastHash[sessionID] = contentHash
            lastChange[sessionID] = now
        }
        lock.unlock()
        if changed { schedulePublish() }
    }

    /// When the session's content last changed, or nil if never seen.
    public func lastOutput(for sessionID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastChange[sessionID]
    }

    /// The session's SSH process went down. Ignore reported content until it
    /// reconnects (disconnect banners / partial screens aren't real changes),
    /// preserving the prior idle time.
    public func markDisconnected(sessionID: String) {
        lock.lock(); suppressUntil[sessionID] = .distantFuture; lock.unlock()
    }

    /// The session's process (re)started. On a reconnect (we already have a
    /// content baseline) ignore reports for a grace window so the tmux
    /// re-attach redraw settles before we compare — it restores old content,
    /// not new output. The first-ever connect baselines immediately.
    public func markConnected(sessionID: String, grace: TimeInterval = 8) {
        lock.lock()
        if lastHash[sessionID] != nil {
            suppressUntil[sessionID] = Date().addingTimeInterval(grace)
        } else {
            suppressUntil[sessionID] = nil
        }
        lock.unlock()
    }

    /// Coalesce UI updates to ~1 Hz on the main thread.
    private func schedulePublish() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.publishScheduled else { return }
            self.publishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.publishScheduled = false
                self.objectWillChange.send()
            }
        }
    }
}
