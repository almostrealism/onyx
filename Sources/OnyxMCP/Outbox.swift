//
// Outbox.swift
//
// Responsibility: Alerts that couldn't be delivered, kept until they can
//                 be — or until they stop mattering.
// Scope: OnyxMCP only. Lives on the machine the agent runs on, beside the
//        rest of what Onyx puts in ~/.onyx.
//
// Why this exists: "nobody is around, undeliverable" was treated as the
// end of the story. It isn't. An agent that finishes at 2am and finds the
// desktop unreachable has still finished, and the person still wants to
// know — the alert is not less true for arriving late. Dropping it silently
// puts the cost of an infrastructure problem onto the one message that was
// worth sending.
//
// Deliberately small and file-based: one JSON object per line, appended,
// rewritten on flush. No database, no daemon. The bridge is a short-lived
// process on someone else's machine and this has to survive it being
// killed at any moment, which a line-oriented file does and an in-memory
// queue does not.
//
// 24 hours, because by then the moment has passed. A queue that replays a
// day-old "the build is done" is noise, and noise is how people learn to
// ignore alerts.
//

import Foundation
// flock/open/close come from the platform's C library. Foundation
// re-exports Darwin on a Mac, which is why this file built there without
// it; on Linux it does not.
#if canImport(Glibc)
import Glibc
#endif

final class Outbox {
    /// One queued request, with when the agent actually sent it.
    struct Entry {
        let at: Date
        /// The original JSON-RPC line, replayed verbatim.
        let line: String
    }

    static let expiry: TimeInterval = 24 * 60 * 60
    /// A runaway agent must not fill someone's disk. Oldest go first.
    static let maxEntries = 200

    private let url: URL
    private let lockPath: String

    init(directory: String? = nil) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = directory ?? (home + "/.onyx")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: dir + "/outbox.jsonl")
        lockPath = dir + "/outbox.lock"
    }

    /// Serialize read-modify-write ACROSS PROCESSES, not just threads.
    ///
    /// An NSLock was wrong here and a test caught it: one host routinely
    /// runs several Claude sessions, each with its own bridge process, all
    /// appending to the same file. Every one of them did load-modify-save,
    /// and the last writer erased the others' alerts — losing an alert
    /// inside the mechanism whose entire purpose is not losing alerts.
    ///
    /// `flock` is the portable answer (macOS and Linux both), and because
    /// each call opens its own descriptor it serializes threads in one
    /// process as well. Best-effort: if the lock file can't be opened, do
    /// the work anyway rather than dropping the alert.
    private func withFileLock<T>(_ body: () -> T) -> T {
        // Two-argument `open`: the three-argument form is variadic in
        // Glibc's headers and isn't reliably importable, so the file is
        // created through FileManager first. Both processes racing to
        // create it is fine — they end in the same place.
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        let fd = open(lockPath, O_RDWR)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    // MARK: - Reading and writing

    private func load() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = object["at"] as? Double,
                  let request = object["request"] as? String else { return nil }
            return Entry(at: Date(timeIntervalSince1970: at), line: request)
        }
    }

    private func save(_ entries: [Entry]) {
        let text = entries.compactMap { entry -> String? in
            let object: [String: Any] = ["at": entry.at.timeIntervalSince1970,
                                         "request": entry.line]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }.joined(separator: "\n")
        try? (text + (text.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Queue a request that couldn't be delivered. Returns how many are
    /// now waiting.
    @discardableResult
    func enqueue(_ line: String, at: Date = Date()) -> Int {
        withFileLock {
            var entries = Self.live(load())
            entries.append(Entry(at: at, line: line))
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
            save(entries)
            return entries.count
        }
    }

    /// Entries still worth delivering, oldest first.
    ///
    /// Unlocked on purpose: `save` writes atomically (temp file, then
    /// rename), so a reader sees one whole version or another, never a
    /// half-written one. Only read-modify-write needs the lock.
    func pending() -> [Entry] {
        Self.live(load()).sorted { $0.at < $1.at }
    }

    var count: Int { pending().count }
    var isEmpty: Bool { pending().isEmpty }

    /// Drop everything that has aged out, and report how many went.
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        withFileLock {
            let all = load()
            let live = Self.live(all, now: now)
            if live.count != all.count { save(live) }
            return all.count - live.count
        }
    }

    static func live(_ entries: [Entry], now: Date = Date()) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.at) < expiry }
    }

    /// Try to deliver everything waiting.
    ///
    /// `send` returns the backend's reply, or nil when it still can't be
    /// reached. The first failure STOPS the flush: the backend is either
    /// there or it isn't, and hammering it with the rest of the queue only
    /// delays the next attempt. Anything not delivered stays queued in its
    /// original order.
    @discardableResult
    func flush(now: Date = Date(), send: (String) -> String?) -> (delivered: Int, remaining: Int) {
        let queued = pending()
        guard !queued.isEmpty else { return (0, 0) }

        // Delivering can take tens of seconds, and the lock is NOT held
        // across it: the agent must be able to queue another alert while
        // this runs.
        var delivered: [Entry] = []
        for entry in queued {
            guard send(Self.replayable(entry)) != nil else { break }
            delivered.append(entry)
        }

        // …which is exactly why the file is re-read here and only the
        // DELIVERED entries are removed. Writing back a list captured
        // before the sends would silently drop anything queued in the
        // meantime — losing an alert inside the mechanism whose whole
        // purpose is not losing alerts.
        let live: [Entry] = withFileLock {
            var keep = load()
            for entry in delivered {
                if let index = keep.firstIndex(where: {
                    $0.line == entry.line && $0.at == entry.at
                }) {
                    keep.remove(at: index)
                }
            }
            let live = Self.live(keep, now: now)
            save(live)
            return live
        }
        return (delivered.count, live.count)
    }

    /// The line to send, carrying WHEN it was originally sent.
    ///
    /// Without this a queued alert shows the time it was finally
    /// delivered, which is the one piece of information that would make it
    /// misleading — "finished at 9am" for work that finished at 2am.
    static func replayable(_ entry: Entry) -> String {
        guard let data = entry.line.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var params = object["params"] as? [String: Any],
              var arguments = params["arguments"] as? [String: Any] else { return entry.line }
        arguments["queued_at"] = entry.at.timeIntervalSince1970
        params["arguments"] = arguments
        object["params"] = params
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: encoded, encoding: .utf8) else { return entry.line }
        return line
    }

    /// Whether a request is one worth keeping if it can't be delivered.
    ///
    /// Only alerts. Publishing a status page to a desktop nobody can reach
    /// is pointless to replay — by the time it lands the page is stale, and
    /// the agent will publish a fresh one next time. An alert is different:
    /// it is a message to a person, and it stays true.
    static func isWorthQueueing(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "tools/call",
              let params = object["params"] as? [String: Any] else { return false }
        return params["name"] as? String == "notify"
    }
}
