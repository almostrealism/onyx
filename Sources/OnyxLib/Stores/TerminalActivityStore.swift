//
// TerminalActivityStore.swift
//
// Responsibility: Records the time each session's terminal last produced
//                 output, so the monitor overlay can show how long a
//                 session has been quiet — a quick "is it still working or
//                 has it gone idle?" signal for sessions running tests etc.
// Scope: Shared singleton.
// Threading: dataReceived may fire off the main thread, so the map is
//            guarded by a lock. UI invalidations are coalesced to at most
//            one per second on the main thread.
//

import Foundation
import Combine

public final class TerminalActivityStore: ObservableObject {

    public static let shared = TerminalActivityStore()

    private let lock = NSLock()
    private var lastOutputBySession: [String: Date] = [:]
    /// Output before this instant is ignored for a session — used to drop
    /// reconnect noise (SSH "connection closed" messages, the tmux re-attach
    /// redraw) so a session that's been idle for hours doesn't look freshly
    /// active just because the connection bounced.
    private var suppressUntil: [String: Date] = [:]
    /// True while a coalesced objectWillChange is already pending on main.
    private var publishScheduled = false

    private init() {}

    /// Stamp "output just happened" for a session. Called for every chunk
    /// of terminal bytes, so it must stay cheap. Ignored while the session
    /// is suppressed (disconnected / within the post-reconnect grace).
    public func recordOutput(sessionID: String) {
        let now = Date()
        lock.lock()
        if let until = suppressUntil[sessionID], now < until { lock.unlock(); return }
        lastOutputBySession[sessionID] = now
        lock.unlock()
        schedulePublish()
    }

    /// When the session last produced output, or nil if never seen.
    public func lastOutput(for sessionID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastOutputBySession[sessionID]
    }

    /// The session's SSH process went down. Ignore everything until it's
    /// back up — disconnect banners and reconnect chatter aren't real
    /// program output, and the prior idle time must be preserved.
    public func markDisconnected(sessionID: String) {
        lock.lock(); suppressUntil[sessionID] = .distantFuture; lock.unlock()
    }

    /// The session's process (re)started. On a *reconnect* (we already have
    /// an idle reading) ignore output for a short grace window to swallow
    /// the tmux re-attach redraw — which restores old content, not new
    /// output. On the very *first* connect, seed the clock and allow output
    /// immediately so a session opened mid-build shows active right away.
    public func markConnected(sessionID: String, grace: TimeInterval = 6) {
        lock.lock()
        if lastOutputBySession[sessionID] != nil {
            suppressUntil[sessionID] = Date().addingTimeInterval(grace)
        } else {
            lastOutputBySession[sessionID] = Date()
            suppressUntil[sessionID] = nil
        }
        lock.unlock()
        schedulePublish()
    }

    /// Coalesce UI updates: output can arrive hundreds of times a second,
    /// but the relative-time display only needs ~1 Hz.
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
