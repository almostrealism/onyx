//
// FleetSeries.swift
//
// Responsibility: Turns the per-host sample buffers in CPUStreamStore into
//                 the aligned series the fleet monitor layouts draw —
//                 bucketing, de-duplication, activity ranking, and the
//                 cross-host max used by the merged view.
// Scope: Service. Pure functions over Models; no state, no I/O, no clock
//        of its own (callers pass `now`), which is what makes the whole
//        thing testable.
//
// The one invariant everything here exists to protect: EVERY host's
// series is bucketed against the SAME wall-clock boundaries. The point of
// stacking machines vertically is to read a spike on one against a spike
// on another, and that only works if column N means the same twenty
// seconds on every row. So buckets are anchored to absolute time — never
// to "the last N samples of this host", which would silently shear the
// rows apart whenever one host missed a poll.
//

import Foundation

/// One host's aligned view of the fleet window.
public struct FleetHostSeries: Identifiable, Equatable {
    /// CPUStreamStore's host key (a HostConfig UUID string).
    public let id: String
    public let label: String
    /// CPU% per bucket, oldest first. Always `bucketCount` long.
    public let cpu: [Double]
    /// GPU% per bucket, or nil when this host has never reported a GPU.
    public let gpu: [Double]?
    /// Memory as % of the host's own total, or nil when unknown.
    public let mem: [Double]?
    /// Highest max(cpu, gpu) seen anywhere in the window — the ranking
    /// key when there are more hosts than slots.
    public let peak: Double
    /// Whether any sample at all landed inside the window.
    ///
    /// Not the same question as "is the series all zeros". An idle
    /// machine reports 0% and MUST still be drawn — a flat line at the
    /// bottom is the answer to "is anything happening over there". A
    /// host we simply haven't heard from has the identical series and
    /// must NOT be drawn, because a flat line would be a lie about it.
    public let hasData: Bool

    public init(id: String, label: String, cpu: [Double], gpu: [Double]?,
                mem: [Double]?, peak: Double, hasData: Bool) {
        self.id = id
        self.label = label
        self.cpu = cpu
        self.gpu = gpu
        self.mem = mem
        self.peak = peak
        self.hasData = hasData
    }
}

public enum FleetSeries {
    /// Columns per chart. Matches the single-host charts so the two
    /// layouts look like the same instrument.
    public static let bucketCount = 60
    /// Seconds per bucket, by the overlay's T setting.
    ///
    /// The fleet sweep is fixed at 10s — it's shared with the screensaver
    /// and doubling it would double every host's SSH load — so T can't
    /// change how often we SAMPLE the fleet the way it does for the
    /// active host. What it changes here is the WINDOW: 10s columns show
    /// the last 10 minutes at one sample each, 60s columns show the last
    /// hour averaged. Same instrument, different zoom.
    public static func bucketSeconds(shortInterval: Bool) -> TimeInterval {
        shortInterval ? 10 : 60
    }

    /// Default bucket width, used where no T setting is in scope.
    public static let bucketSeconds: TimeInterval = 10
    /// How many hosts the stacked layout will draw. Past this the rows
    /// are too short to read, which defeats the point of having them.
    public static let defaultLimit = 5

    /// Build the ranked, de-duplicated, aligned series for the fleet
    /// layouts.
    ///
    /// `hosts` supplies the SSH identity behind each stream so two host
    /// entries pointing at the same machine collapse to one row — a
    /// common setup (same box, different default tmux session) that would
    /// otherwise draw the same chart twice and burn two of five slots.
    ///
    /// Local hosts are excluded: these layouts are about the machines you
    /// can't see, and your own Mac is already the subject of every other
    /// view in the overlay.
    public static func build(streams: [HostCPUStream],
                             hosts: [HostConfig],
                             now: Date = Date(),
                             limit: Int = defaultLimit,
                             bucketSeconds: TimeInterval = bucketSeconds) -> [FleetHostSeries] {
        let byID = Dictionary(hosts.map { ($0.id.uuidString, $0) },
                              uniquingKeysWith: { first, _ in first })

        var claimed: [String: String] = [:]   // ssh identity -> winning hostID
        var candidates: [FleetHostSeries] = []

        for stream in streams {
            guard let host = byID[stream.hostID] else { continue }
            if host.isLocal { continue }
            let series = series(for: stream, now: now, bucketSeconds: bucketSeconds)
            // Silence is not the same as idleness — see `hasData`.
            guard series.hasData else { continue }

            let identity = sshIdentity(host)
            if let winner = claimed[identity] {
                // Same machine, second entry. Keep whichever has more to
                // show rather than whichever happened to be first.
                if let idx = candidates.firstIndex(where: { $0.id == winner }),
                   series.peak > candidates[idx].peak {
                    candidates[idx] = series
                    claimed[identity] = series.id
                }
                continue
            }
            claimed[identity] = series.id
            candidates.append(series)
        }

        // Busiest first, then by label so the order is stable frame to
        // frame when several hosts are equally idle (all-zero peaks are
        // the common case overnight, and rows jumping around would be
        // worse than any ranking).
        return Array(candidates
            .sorted { $0.peak == $1.peak ? $0.label < $1.label : $0.peak > $1.peak }
            .prefix(max(0, limit)))
    }

    /// Per-bucket maximum across every host — "if anyone is busy, we're
    /// busy". Buckets where no host reported anything stay 0.
    ///
    /// Hosts that don't have the series at all (no GPU, say) contribute
    /// nothing rather than contributing a zero, so one GPU-less machine
    /// can't drag the fleet's GPU line down.
    public static func mergedMax(_ series: [FleetHostSeries],
                                 _ keyPath: KeyPath<FleetHostSeries, [Double]?>) -> [Double] {
        let present = series.compactMap { $0[keyPath: keyPath] }
        return mergeMaxColumns(present)
    }

    /// The CPU overload — CPU is never nil, so it needs its own path.
    public static func mergedMaxCPU(_ series: [FleetHostSeries]) -> [Double] {
        mergeMaxColumns(series.map(\.cpu))
    }

    private static func mergeMaxColumns(_ columns: [[Double]]) -> [Double] {
        guard !columns.isEmpty else { return [] }
        var out = [Double](repeating: 0, count: bucketCount)
        for row in columns {
            for i in 0..<min(bucketCount, row.count) where row[i] > out[i] {
                out[i] = row[i]
            }
        }
        return out
    }

    /// Bucket one host's samples onto the shared grid.
    static func series(for stream: HostCPUStream, now: Date,
                       bucketSeconds: TimeInterval = bucketSeconds) -> FleetHostSeries {
        let (start, end) = window(now: now, bucketSeconds: bucketSeconds)
        let hasData = stream.samples.contains { $0.t >= start && $0.t < end + bucketSeconds }

        let cpu = bucket(stream.samples, now: now, bucketSeconds: bucketSeconds) { $0.cpu }
        let gpuValues = bucket(stream.samples, now: now, bucketSeconds: bucketSeconds) { $0.gpu }
        let memValues = bucket(stream.samples, now: now, bucketSeconds: bucketSeconds) { $0.memPercent }

        let sawGPU = stream.samples.contains { $0.gpu != nil }
        let sawMem = stream.samples.contains { $0.memPercent != nil }

        let peak = max(cpu.max() ?? 0, sawGPU ? (gpuValues.max() ?? 0) : 0)
        return FleetHostSeries(id: stream.hostID,
                               label: stream.label,
                               cpu: cpu,
                               gpu: sawGPU ? gpuValues : nil,
                               mem: sawMem ? memValues : nil,
                               peak: peak,
                               hasData: hasData)
    }

    /// Average the samples falling in each fixed wall-clock bucket.
    ///
    /// The grid is anchored by flooring `now` to a bucket boundary, so
    /// the rightmost column always covers the same real interval for
    /// every host in the same frame — that alignment is the entire
    /// reason these layouts exist. Empty buckets read 0.
    static func bucket(_ samples: [CPUStreamSample],
                       now: Date,
                       bucketSeconds: TimeInterval = bucketSeconds,
                       value: (CPUStreamSample) -> Double?) -> [Double] {
        let (start, _) = window(now: now, bucketSeconds: bucketSeconds)

        var sums = [Double](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)

        for sample in samples {
            guard let v = value(sample) else { continue }
            let idx = Int(floor((sample.t - start) / bucketSeconds))
            guard idx >= 0 && idx < bucketCount else { continue }
            sums[idx] += v
            counts[idx] += 1
        }

        return (0..<bucketCount).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    }

    /// The window every host is bucketed against: `end` is the start of
    /// the in-progress bucket (floored to a boundary so the grid doesn't
    /// slide under the charts between frames), and `start` is
    /// `bucketCount - 1` buckets before it.
    static func window(now: Date,
                       bucketSeconds: TimeInterval = bucketSeconds)
        -> (start: TimeInterval, end: TimeInterval) {
        let end = floor(now.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
        return (end - Double(bucketCount - 1) * bucketSeconds, end)
    }

    /// What makes two host entries the same machine. Port included: two
    /// entries differing only by port are genuinely different endpoints.
    static func sshIdentity(_ host: HostConfig) -> String {
        let h = host.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let u = host.ssh.user.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(u)@\(h):\(host.ssh.port)"
    }
}
