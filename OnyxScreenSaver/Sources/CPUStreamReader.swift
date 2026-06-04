import Foundation

/// Polls the Onyx app's cpu-stream.json file and surfaces decoded snapshots
/// to its delegate. The screensaver runs as the logged-in user, so the
/// Application Support path resolves to the same location Onyx writes to.
///
/// Polling beats kqueue here because the file lives under
/// `Library/Application Support/`, which is iCloud-backed on some setups —
/// kqueue notifications don't always fire reliably there. Cheap mtime
/// checks at 500ms give us near-realtime updates without that flakiness.
final class CPUStreamReader {

    /// Called on the main queue whenever a new snapshot is read.
    /// `hosts` will be empty if the file decoded cleanly but had no hosts yet.
    /// `weeklyHours` is nil when the publisher hasn't sent a value (older
    /// builds) or when Timing.app isn't configured.
    /// `weeklyProjects` carries the per-project breakdown for ball coloring.
    var onUpdate: ((_ hosts: [HostStream],
                    _ weeklyHours: Double?,
                    _ weeklyProjects: [ProjectShare]?) -> Void)?

    /// Called on the main queue when the file is missing or its `updatedAt`
    /// is older than `staleThreshold`. The screensaver renders its idle
    /// state in this case (mock data driver in `SculptureScene`).
    var onIdle: (() -> Void)?

    /// Path to the JSON file Onyx publishes. Resolves to the screensaver
    /// process's home, which is the GUI user — same path Onyx writes to.
    let url: URL

    /// How long since the file's `updatedAt` we consider it dead. Anything
    /// older and we assume Onyx isn't running.
    static let staleThreshold: TimeInterval = 30

    /// Polling interval. 500ms is a good balance — visibly responsive
    /// without measurable CPU cost (just an fstat per tick).
    static let pollInterval: TimeInterval = 0.5

    private var timer: Timer?
    private var lastMtime: TimeInterval?
    private var lastWasIdle = false
    /// Cached decoder — JSONDecoder is reusable and not creating a
    /// fresh one per tick avoids ~thousands of small allocations per
    /// hour over a long saver session.
    private let decoder = JSONDecoder()

    init() {
        // /Users/Shared is reachable from the legacyScreenSaver sandbox;
        // ~/Library/Application Support is not. The Onyx app writes the
        // same path from AppState.cpuStreamURL — see CLAUDE.md / the
        // screensaver plan doc for context.
        url = URL(fileURLWithPath: "/Users/Shared/Onyx/cpu-stream.json")
    }

    func start() {
        tick()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot guard so we only log the "first time we ever saw / failed
    /// to see" the file. Continuous tick-by-tick logging would flood
    /// Console.app at 2 messages per second.
    private var loggedFirstResult = false

    // MARK: - Tick

    private func tick() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            logFirstResult("stat failed for \(url.path) — file missing or sandbox blocks read")
            emitIdleIfNeeded()
            return
        }

        // mtime didn't move — same content, nothing to do.
        if let last = lastMtime, last == mtime.timeIntervalSince1970 { return }
        lastMtime = mtime.timeIntervalSince1970

        do {
            let data = try Data(contentsOf: url)
            let file = try decoder.decode(CPUStreamFile.self, from: data)

            let age = Date().timeIntervalSince1970 - file.updatedAt
            if age > Self.staleThreshold {
                logFirstResult("file stale by \(Int(age))s — Onyx not writing? updatedAt=\(file.updatedAt)")
                emitIdleIfNeeded()
                return
            }

            logFirstResult("LIVE — \(file.hosts.count) host(s), age=\(String(format: "%.1f", age))s, weeklyHours=\(file.weeklyHours.map { String(format: "%.1f", $0) } ?? "nil"), projects=\(file.weeklyProjects?.count ?? 0)")
            lastWasIdle = false
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(file.hosts, file.weeklyHours, file.weeklyProjects)
            }
        } catch {
            // File exists but decode failed — could be caught mid-write
            // despite atomic-rename, OR sandbox-denied read returning empty.
            logFirstResult("read/decode failed: \(error)")
            return
        }
    }

    /// NSLog through to Console.app's unified log. Filter for "OnyxSaver"
    /// in Console.app to see only our messages. The first tick result is
    /// logged unconditionally; later messages only fire when state changes.
    private func logFirstResult(_ msg: String) {
        if !loggedFirstResult {
            loggedFirstResult = true
            NSLog("[OnyxSaver] first tick: \(msg)")
        }
    }

    private func emitIdleIfNeeded() {
        guard !lastWasIdle else { return }
        lastWasIdle = true
        DispatchQueue.main.async { [weak self] in
            self?.onIdle?()
        }
    }
}
