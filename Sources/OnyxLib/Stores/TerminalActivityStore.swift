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
    /// True while a coalesced objectWillChange is already pending on main.
    private var publishScheduled = false

    private init() {}

    /// Stamp "output just happened" for a session. Called for every chunk
    /// of terminal bytes, so it must stay cheap.
    public func recordOutput(sessionID: String) {
        let now = Date()
        lock.lock(); lastOutputBySession[sessionID] = now; lock.unlock()
        schedulePublish()
    }

    /// When the session last produced output, or nil if never seen.
    public func lastOutput(for sessionID: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastOutputBySession[sessionID]
    }

    /// Drop a session's record (on pool teardown) so the map can't grow
    /// without bound across reconnects.
    public func forget(sessionID: String) {
        lock.lock()
        let existed = lastOutputBySession.removeValue(forKey: sessionID) != nil
        lock.unlock()
        if existed { schedulePublish() }
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
