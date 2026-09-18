//
// Ledger.swift
//
// Responsibility: What this host knows about Onyx — every desktop that has
//                 ever answered from here, when each was last heard from,
//                 and what went wrong when nothing was.
// Scope: OnyxMCP only. One file per host in ~/.onyx, shared by every
//        bridge process on it, locked the same way the outbox is.
//
// Why this exists: an agent whose tool call fails used to be told "Onyx
// backend unreachable", and nothing else. That is not a diagnosis, it is
// a shrug — and an agent handed a shrug concludes "it's broken" and tells
// the user so, with nothing the user can act on either. The questions
// that actually distinguish the failures are cheap to answer IF someone
// has been keeping notes: Has Onyx EVER answered from this host? Which
// desktop, over which route, how long ago? What did the last attempt see
// — a refused connection, a port that went silent, a peer that wasn't
// Onyx? Those notes are this file.
//
// "Connected" is a property of a bridge process; "seen" is a property of
// the host. This tracks the second, because the first evaporates every
// time a Claude session ends.
//

import Foundation
#if canImport(Glibc)
import Glibc
#endif

final class Ledger {

    /// A desktop that has answered from this host.
    struct Desktop: Codable, Equatable {
        var machine: String
        var version: String
        var route: String
        var firstSeen: Date
        var lastSeen: Date
        var answers: Int
    }

    struct Failure: Codable, Equatable {
        var at: Date
        let route: String
        let reason: String
        /// How many times in a row. A retry loop that fails the same way
        /// forty times is one fact, not forty lines.
        var count: Int = 1

        init(at: Date, route: String, reason: String, count: Int = 1) {
            self.at = at; self.route = route; self.reason = reason; self.count = count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try c.decode(Date.self, forKey: .at)
            route = try c.decode(String.self, forKey: .route)
            reason = try c.decode(String.self, forKey: .reason)
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        }

        private enum CodingKeys: String, CodingKey { case at, route, reason, count }
    }

    struct Record: Codable, Equatable {
        /// Keyed by machine name.
        var desktops: [String: Desktop] = [:]
        /// Newest last, bounded.
        var failures: [Failure] = []
        var lastSuccess: Date?
        var lastSuccessRoute: String?
    }

    static let maxFailures = 20

    private let url: URL
    private let lockPath: String
    /// A request that succeeds writes the ledger, and a busy agent makes
    /// many requests; this keeps the file from being rewritten on every
    /// one for a timestamp nobody needs to the second.
    private var lastSuccessWrite: Date = .distantPast

    init(directory: String? = nil) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = directory ?? (home + "/.onyx")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: dir + "/mcp-ledger.json")
        lockPath = dir + "/mcp-ledger.lock"
    }

    // MARK: - Storage

    private func withFileLock<T>(_ body: () -> T) -> T {
        if !FileManager.default.fileExists(atPath: lockPath) {
            FileManager.default.createFile(atPath: lockPath, contents: nil)
        }
        let fd = open(lockPath, O_RDWR)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    private func load() -> Record {
        guard let data = try? Data(contentsOf: url),
              let record = try? Self.decoder.decode(Record.self, from: data) else { return Record() }
        return record
    }

    private func save(_ record: Record) {
        guard let data = try? Self.encoder.encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func snapshot() -> Record { load() }

    // MARK: - Recording

    /// A desktop answered, and said who it is.
    func sawDesktop(machine: String, version: String, route: String, now: Date = Date()) {
        withFileLock {
            var record = load()
            var entry = record.desktops[machine]
                ?? Desktop(machine: machine, version: version, route: route,
                           firstSeen: now, lastSeen: now, answers: 0)
            entry.version = version
            entry.route = route
            entry.lastSeen = now
            entry.answers += 1
            record.desktops[machine] = entry
            record.lastSuccess = now
            record.lastSuccessRoute = route
            save(record)
            lastSuccessWrite = now
        }
    }

    /// A request went through. Throttled — see `lastSuccessWrite`.
    func sawSuccess(route: String, now: Date = Date()) {
        guard now.timeIntervalSince(lastSuccessWrite) > 10 else { return }
        withFileLock {
            var record = load()
            record.lastSuccess = now
            record.lastSuccessRoute = route
            // The desktop last seen on this route is the one still talking.
            if let key = record.desktops.first(where: { $0.value.route == route })?.key {
                record.desktops[key]?.lastSeen = now
            }
            save(record)
            lastSuccessWrite = now
        }
    }

    func sawFailure(route: String, reason: String, now: Date = Date()) {
        withFileLock {
            var record = load()
            if let last = record.failures.last, last.route == route, last.reason == reason {
                record.failures[record.failures.count - 1].at = now
                record.failures[record.failures.count - 1].count += 1
            } else {
                record.failures.append(Failure(at: now, route: route, reason: reason))
            }
            if record.failures.count > Self.maxFailures {
                record.failures.removeFirst(record.failures.count - Self.maxFailures)
            }
            save(record)
        }
    }

    // MARK: - Telling people

    /// Whether anything on this host has ever reached Onyx. The single
    /// most useful fact for an agent: "never" means the install is
    /// incomplete; "yesterday" means something changed.
    static func hasEverConnected(_ record: Record) -> Bool {
        record.lastSuccess != nil
    }

    /// One paragraph for an error message. Every sentence is a fact an
    /// agent can act on or relay; "unreachable" alone is neither.
    static func summary(_ record: Record, outboxWaiting: Int = 0,
                        now: Date = Date()) -> String {
        var parts: [String] = []

        if let last = record.lastSuccess {
            let who = record.desktops.values
                .max(by: { $0.lastSeen < $1.lastSeen })
                .map { " (\($0.machine), Onyx \($0.version))" } ?? ""
            parts.append("Onyx last answered from this host \(ago(last, now: now))"
                         + who + " via \(record.lastSuccessRoute ?? "?").")
        } else {
            parts.append("Onyx has NEVER answered from this host — the bridge is installed "
                         + "here, but no route to a desktop has ever worked. That is an "
                         + "install or connection problem, not a momentary one.")
        }

        if let failure = record.failures.last {
            parts.append("Last attempt \(ago(failure.at, now: now)): "
                         + "\(failure.route) — \(failure.reason)"
                         + (failure.count > 1 ? " (\(failure.count) times in a row)." : "."))
        }

        if outboxWaiting > 0 {
            parts.append("\(outboxWaiting) alert(s) are queued here and will be delivered "
                         + "when Onyx is reachable.")
        }

        parts.append("Likely: the Onyx desktop is closed, or its ssh connection to this host "
                     + "dropped and the port forward went with it. "
                     + "`OnyxMCP --status` on this host shows every route and desktop.")
        return parts.joined(separator: " ")
    }

    /// The full picture, for `--status` and the `onyx_status` tool.
    static func report(_ record: Record, host: String, version: String,
                       routes: [(route: String, verdict: String, ok: Bool)],
                       outboxWaiting: Int, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("OnyxMCP \(version) on \(host)")
        lines.append("")

        lines.append("Routes to Onyx, right now:")
        for r in routes {
            lines.append("  \(r.ok ? "YES" : "no ")  \(r.route) — \(r.verdict)")
        }
        lines.append("")

        lines.append("Desktops that have answered from this host:")
        if record.desktops.isEmpty {
            lines.append("  none, ever — no route to a desktop has worked from here")
        }
        for d in record.desktops.values.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let live = routes.contains { $0.ok && $0.route == d.route }
            lines.append("  \(d.machine)  Onyx \(d.version)  via \(d.route)"
                         + "  last answered \(ago(d.lastSeen, now: now))"
                         + "  (\(d.answers) request\(d.answers == 1 ? "" : "s") since \(short(d.firstSeen)))"
                         + (live ? "  ← reachable now" : ""))
        }
        lines.append("")

        if !record.failures.isEmpty {
            lines.append("Recent failures (newest last):")
            for f in record.failures.suffix(8) {
                lines.append("  \(short(f.at))  \(f.route) — \(f.reason)"
                             + (f.count > 1 ? "  (×\(f.count))" : ""))
            }
            lines.append("")
        }

        lines.append(outboxWaiting > 0
                     ? "Outbox: \(outboxWaiting) alert(s) waiting for a route to open."
                     : "Outbox: empty.")
        return lines.joined(separator: "\n")
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 90 { return "\(s)s ago" }
        if s < 5400 { return "\(s / 60) min ago" }
        if s < 129_600 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    static func short(_ date: Date) -> String { stamp.string(from: date) }
}
