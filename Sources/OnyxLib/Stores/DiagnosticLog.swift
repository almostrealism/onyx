//
// DiagnosticLog.swift
//
// Responsibility: A short in-app history of the events that explain
//                 connection behaviour — probe failures, key-setup
//                 decisions, slot deaths, promotions, failed polls.
// Scope: Shared singleton, memory only (never persisted; it's a
//        troubleshooting aid, not a record).
// Threading: Lock-guarded; `entries` republished on main for SwiftUI.
//
// Why this exists: every one of this month's bugs was diagnosed by
// finding out what the remote actually said — and every time, the answer
// lived in the unified log, which meant "please run `log show` and paste
// the output". That round trip failed as often as it worked (wrong
// window, filtered level, nothing matched the grep). The evidence should
// be in the app, next to the thing that's misbehaving.
//

import Foundation
import Combine

public final class DiagnosticLog: ObservableObject {

    public static let shared = DiagnosticLog()

    public struct Entry: Identifiable, Equatable {
        public let id = UUID()
        public let at: Date
        public let category: String
        public let message: String
        /// Rendered differently — these are the ones worth noticing.
        public let isFailure: Bool
    }

    /// Newest first. Capped: this is a window, not a archive.
    @Published public private(set) var entries: [Entry] = []

    private let lock = NSLock()
    private let limit = 200

    private init() {}

    public func record(_ category: String, _ message: String, failure: Bool = false) {
        let entry = Entry(at: Date(), category: category, message: message, isFailure: failure)
        DispatchQueue.main.async {
            self.lock.lock()
            var next = self.entries
            next.insert(entry, at: 0)
            if next.count > self.limit { next.removeLast(next.count - self.limit) }
            self.entries = next
            self.lock.unlock()
        }
    }

    /// Most recent entries, newest first.
    public func recent(_ count: Int) -> [Entry] {
        Array(entries.prefix(count))
    }

    /// Everything since a moment — used to answer "what happened in the
    /// last few minutes" without scrolling.
    public func since(_ date: Date) -> [Entry] {
        entries.filter { $0.at >= date }
    }

    public func clear() {
        DispatchQueue.main.async { self.entries = [] }
    }
}
