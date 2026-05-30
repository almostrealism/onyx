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
    var onUpdate: (([HostStream]) -> Void)?

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

    // MARK: - Tick

    private func tick() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            emitIdleIfNeeded()
            return
        }

        // mtime didn't move — same content, nothing to do.
        if let last = lastMtime, last == mtime.timeIntervalSince1970 { return }
        lastMtime = mtime.timeIntervalSince1970

        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CPUStreamFile.self, from: data) else {
            // File exists but decode failed — likely caught mid-write despite
            // the publisher's atomic-rename. Wait for the next tick.
            return
        }

        let age = Date().timeIntervalSince1970 - file.updatedAt
        if age > Self.staleThreshold {
            emitIdleIfNeeded()
            return
        }

        lastWasIdle = false
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(file.hosts)
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
