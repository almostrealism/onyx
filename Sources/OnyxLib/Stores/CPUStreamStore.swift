//
// CPUStreamStore.swift
//
// Responsibility: Owns the in-memory per-host CPU sample ring buffers that
//                 the screensaver (a separate process) reads from disk.
//                 Writes ~/Library/Application Support/Onyx/cpu-stream.json
//                 atomically and coalesces high-frequency updates into ~500ms
//                 write windows so disk I/O is bounded regardless of how many
//                 callers push samples.
// Scope: Shared singleton (CPUStreamStore.shared) — there is exactly one
//        writer process per machine; multiple Onyx windows funnel through
//        this one store.
// Threading: NSLock-guarded buffer; writes run on a dedicated serial queue
//            so callers from any thread are safe.
// Invariants:
//   - configure(url:) only takes effect on the first call
//   - per-host samples are capped at maxSamplesPerHost (newest kept)
//   - writes are atomic (temp file + rename) so partial reads are impossible
//   - hosts removed via removeHost(_:) drop out of the next write
//
// The wire format types live in HostCPUStream below — keep them in sync
// with OnyxScreenSaver/Sources/StreamModels.swift, which decodes the same
// JSON on the other side of the file boundary.
//

import Foundation

/// One CPU sample at a point in time. Mirrors the screensaver's `CPUSample`.
/// `gpu` is optional — null means "no GPU on this host". The screensaver
/// uses it to render the outer "Saturn ring" of GPU activity history.
public struct CPUStreamSample: Codable, Equatable {
    /// Unix timestamp in seconds.
    public let t: TimeInterval
    /// CPU usage 0..100.
    public let cpu: Double
    /// GPU utilization 0..100, or nil if the host has no GPU sensor.
    public let gpu: Double?

    public init(t: TimeInterval, cpu: Double, gpu: Double? = nil) {
        self.t = t
        self.cpu = cpu
        self.gpu = gpu
    }
}

/// One container running on a host, with its current CPU%. Used by the
/// screensaver to render orbiting "moons" around the host's totem.
public struct ContainerStream: Codable, Equatable {
    public let name: String
    /// CPU usage 0..100 (the docker stats `--format {{.CPUPerc}}` reading).
    public let cpu: Double

    public init(name: String, cpu: Double) {
        self.name = name
        self.cpu = cpu
    }
}

/// One host's stream of recent CPU samples + its currently-running
/// containers. Encodes to the same shape the screensaver expects.
public struct HostCPUStream: Codable, Equatable {
    public let hostID: String
    public let label: String
    public let color: String
    public var samples: [CPUStreamSample]
    /// Currently-running docker containers on this host, if any. Nil
    /// when the host has no docker (or we couldn't reach it); empty
    /// array when docker is present but no containers are up.
    public var containers: [ContainerStream]?

    public init(hostID: String, label: String, color: String,
                samples: [CPUStreamSample],
                containers: [ContainerStream]? = nil) {
        self.hostID = hostID
        self.label = label
        self.color = color
        self.samples = samples
        self.containers = containers
    }
}

/// One Timing.app project's contribution to the current week. The
/// screensaver blends these colors (weighted by hours) to tint the
/// central ball. `color` is a 6-char hex string without `#`, matching
/// what TimingManager publishes.
public struct WeeklyProjectShare: Codable, Equatable {
    public let title: String
    public let color: String
    public let hours: Double

    public init(title: String, color: String, hours: Double) {
        self.title = title; self.color = color; self.hours = hours
    }
}

/// Top-level shape of cpu-stream.json.
///
/// `weeklyHours` and `weeklyProjects` are optional — older publishers
/// won't include them, and the screensaver decodes via decodeIfPresent
/// so a missing field is fine.
public struct CPUStreamFile: Codable, Equatable {
    public let updatedAt: TimeInterval
    public let hosts: [HostCPUStream]
    public let weeklyHours: Double?
    public let weeklyProjects: [WeeklyProjectShare]?

    public init(updatedAt: TimeInterval, hosts: [HostCPUStream],
                weeklyHours: Double? = nil,
                weeklyProjects: [WeeklyProjectShare]? = nil) {
        self.updatedAt = updatedAt
        self.hosts = hosts
        self.weeklyHours = weeklyHours
        self.weeklyProjects = weeklyProjects
    }
}

/// Shared store + publisher for the screensaver's CPU stream file.
public final class CPUStreamStore {

    /// Per-host newest-N samples. 120 ≈ 20 min @ 10s polling, plenty of time
    /// to show meaningful variation while keeping the file small.
    public static let maxSamplesPerHost = 120

    /// Debounce window for disk writes. Multiple samples landing inside the
    /// window collapse into a single rewrite — important because the fleet
    /// poller can fan in N hosts' samples nearly simultaneously.
    public static let writeDebounce: TimeInterval = 0.5

    /// Shared instance.
    public static let shared = CPUStreamStore()

    private var url: URL?
    private var buffers: [String: HostCPUStream] = [:]
    private var weeklyHoursValue: Double?
    private var weeklyProjectsValue: [WeeklyProjectShare]?
    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.onyx.cpu-stream-writer")
    private var pendingWriteWorkItem: DispatchWorkItem?

    /// Override for tests — when non-nil, replaces `Date().timeIntervalSince1970`
    /// in `updatedAt`. Production code never sets this.
    public var clockOverride: (() -> TimeInterval)?

    private init() {}

    // MARK: - Configuration

    /// Configure the on-disk URL. Only takes effect on the first call; mirrors
    /// the other singleton stores (SessionNotesStore, FavoritesStore).
    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
    }

    /// Test hook — clears all in-memory state and the configured URL so a
    /// fresh setUp() starts from a blank slate. Does not touch any file.
    public func reset() {
        lock.lock()
        buffers.removeAll()
        url = nil
        pendingWriteWorkItem?.cancel()
        pendingWriteWorkItem = nil
        lock.unlock()
    }

    // MARK: - Sample ingestion

    /// Append a CPU sample for a host. Creates the per-host buffer on first
    /// call, caps the buffer at `maxSamplesPerHost`, and schedules a debounced
    /// disk write.
    ///
    /// `color` is a "#RRGGBB" hex string. `label` is the human-readable name
    /// shown above the totem.
    public func appendSample(hostID: String,
                             label: String,
                             color: String,
                             cpu: Double,
                             gpu: Double? = nil,
                             timestamp: TimeInterval) {
        let sample = CPUStreamSample(t: timestamp, cpu: cpu, gpu: gpu)
        lock.lock()
        let existing = buffers[hostID]
        // Label / color may evolve (renamed host, theme change) — keep the
        // latest from the caller rather than freezing at first sight.
        // Containers come from a separate poll path and are preserved
        // across sample appends.
        var stream = HostCPUStream(hostID: hostID, label: label, color: color,
                                   samples: (existing?.samples ?? []) + [sample],
                                   containers: existing?.containers)
        let cap = Self.maxSamplesPerHost
        if stream.samples.count > cap {
            stream.samples.removeFirst(stream.samples.count - cap)
        }
        buffers[hostID] = stream
        lock.unlock()
        scheduleWrite()
    }

    /// Update the docker container list for a host. Idempotent — repeated
    /// calls with the same data produce one file rewrite (debounced).
    /// Nil clears the field (no docker on this host).
    public func setContainers(hostID: String, containers: [ContainerStream]?) {
        lock.lock()
        if var stream = buffers[hostID] {
            stream.containers = containers
            buffers[hostID] = stream
        }
        // If the host doesn't have a buffer yet, the next appendSample
        // creates one and inherits these containers via the existing
        // lookup path — but only if we stash them somewhere. For now,
        // skip: the fleet poller always appends a CPU sample before
        // calling setContainers, so the buffer is guaranteed to exist.
        lock.unlock()
        scheduleWrite()
    }

    /// Update the "hours worked this week" figure shown to the screensaver.
    /// Pass nil to clear it (e.g. Timing.app isn't configured). Anything
    /// less than ~0.1 is treated as nil downstream so a fresh-Monday
    /// zero-hour reading doesn't spawn a degenerate point-mass ball.
    public func setWeeklyHours(_ hours: Double?) {
        lock.lock()
        weeklyHoursValue = hours
        lock.unlock()
        scheduleWrite()
    }

    /// Update the per-project hours breakdown for the current week. Used
    /// by the screensaver to tint the central ball by the blended project
    /// palette. Pass nil or an empty array to clear the tint.
    public func setWeeklyProjects(_ projects: [WeeklyProjectShare]?) {
        lock.lock()
        weeklyProjectsValue = (projects?.isEmpty ?? true) ? nil : projects
        lock.unlock()
        scheduleWrite()
    }

    /// Drop a host from the stream — used when the user removes a host config
    /// so the screensaver stops drawing its totem on the next read.
    public func removeHost(_ hostID: String) {
        lock.lock()
        buffers.removeValue(forKey: hostID)
        lock.unlock()
        scheduleWrite()
    }

    // MARK: - Snapshot (for tests and instrumentation)

    /// Current per-host snapshot. Mostly used by tests.
    public func snapshot() -> [HostCPUStream] {
        lock.lock()
        defer { lock.unlock() }
        return Array(buffers.values).sorted { $0.hostID < $1.hostID }
    }

    /// Force-flush any pending debounced write, blocking until done.
    /// Tests use this to observe disk contents deterministically.
    public func flushForTesting() {
        let item: DispatchWorkItem?
        lock.lock()
        item = pendingWriteWorkItem
        pendingWriteWorkItem = nil
        lock.unlock()
        item?.cancel()
        writerQueue.sync {
            self.performWriteLocked()
        }
    }

    // MARK: - Writer

    private func scheduleWrite() {
        lock.lock()
        pendingWriteWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performWriteLocked() }
        pendingWriteWorkItem = item
        lock.unlock()
        writerQueue.asyncAfter(deadline: .now() + Self.writeDebounce, execute: item)
    }

    /// Encode + atomically write. The "Locked" suffix here means "takes the
    /// lock"; it isn't called with the lock already held.
    private func performWriteLocked() {
        lock.lock()
        guard let url = self.url else { lock.unlock(); return }
        let now = clockOverride?() ?? Date().timeIntervalSince1970
        let payload = CPUStreamFile(
            updatedAt: now,
            hosts: Array(buffers.values).sorted { $0.hostID < $1.hostID },
            weeklyHours: weeklyHoursValue,
            weeklyProjects: weeklyProjectsValue
        )
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Atomic write: temp file in the same directory then rename, so a
        // reader can never observe a partial file.
        let temp = dir.appendingPathComponent(".cpu-stream.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }
}
