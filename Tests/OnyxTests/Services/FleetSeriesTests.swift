import XCTest
@testable import OnyxLib

/// The fleet monitor layouts stand on one promise: column N is the same
/// twenty seconds on every host's row. These lock that promise, plus the
/// ranking and merging rules that decide what gets drawn at all.
final class FleetSeriesTests: XCTestCase {

    /// Fixed "now" so bucket boundaries are deterministic.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func host(_ name: String, user: String = "me", port: Int = 22,
                      local: Bool = false, id: UUID = UUID()) -> HostConfig {
        HostConfig(id: id, label: name,
                   ssh: SSHConfig(host: local ? "localhost" : name, user: user, port: port))
    }

    private func stream(_ id: UUID, label: String,
                        samples: [CPUStreamSample]) -> HostCPUStream {
        HostCPUStream(hostID: id.uuidString, label: label, color: "#FF0000",
                      samples: samples)
    }

    /// t = seconds before `now`.
    private func sample(_ ago: TimeInterval, cpu: Double, gpu: Double? = nil,
                        mem: Double? = nil, memTotal: Double? = nil) -> CPUStreamSample {
        CPUStreamSample(t: now.timeIntervalSince1970 - ago, cpu: cpu, gpu: gpu,
                        mem: mem, memTotal: memTotal)
    }

    // MARK: - Alignment

    /// The reason this whole file exists: two hosts that spiked at the
    /// same wall-clock moment must spike in the same column, even when
    /// one of them has a completely different number of samples.
    func testSpikesAtTheSameMomentLandInTheSameColumn() {
        let a = stream(UUID(), label: "a", samples: [
            sample(300, cpu: 5), sample(200, cpu: 90), sample(10, cpu: 5),
        ])
        // b polls far more often, and its window starts later.
        let b = stream(UUID(), label: "b", samples: (0..<40).map {
            sample(400 - Double($0) * 10, cpu: abs(400 - Double($0) * 10 - 200) < 5 ? 90 : 5)
        })

        let sa = FleetSeries.series(for: a, now: now)
        let sb = FleetSeries.series(for: b, now: now)

        let peakA = sa.cpu.firstIndex(of: sa.cpu.max()!)
        let peakB = sb.cpu.firstIndex(of: sb.cpu.max()!)
        XCTAssertEqual(peakA, peakB,
                       "a spike at the same instant must occupy the same column on every row")
    }

    func testBucketsAreFixedLengthAndOldestFirst() {
        let s = FleetSeries.series(for: stream(UUID(), label: "a", samples: [
            sample(0, cpu: 77),
        ]), now: now)
        XCTAssertEqual(s.cpu.count, FleetSeries.bucketCount)
        XCTAssertEqual(s.cpu.last, 77, "the newest sample belongs in the rightmost column")
        XCTAssertEqual(s.cpu.first, 0, "an empty bucket reads zero, not stale data")
    }

    func testSamplesOlderThanTheWindowAreDropped() {
        let window = Double(FleetSeries.bucketCount) * FleetSeries.bucketSeconds
        let s = FleetSeries.series(for: stream(UUID(), label: "a", samples: [
            sample(window + 600, cpu: 100),   // long gone
            sample(0, cpu: 10),
        ]), now: now)
        XCTAssertEqual(s.cpu.max(), 10, "a sample off the left edge must not reappear")
    }

    func testSamplesInOneBucketAreAveraged() {
        // Ten seconds past a bucket boundary, so both samples fall inside
        // the current column instead of straddling into the previous one.
        let mid = Date(timeIntervalSince1970: 1_770_000_010)
        let t = mid.timeIntervalSince1970
        let s = FleetSeries.series(for: HostCPUStream(
            hostID: "h", label: "a", color: "#FF0000",
            samples: [CPUStreamSample(t: t - 5, cpu: 20),
                      CPUStreamSample(t: t - 2, cpu: 40)]), now: mid)
        XCTAssertEqual(s.cpu.last!, 30, accuracy: 0.001)
    }

    func testAnIdleHostIsDrawnButASilentOneIsNot() {
        // Both produce an all-zero series; only one of them is a fact.
        let idle = host("idle")
        let silent = host("silent")
        let ancient = Double(FleetSeries.bucketCount) * FleetSeries.bucketSeconds + 600

        let built = FleetSeries.build(
            streams: [stream(idle.id, label: "idle", samples: [sample(0, cpu: 0)]),
                      stream(silent.id, label: "silent", samples: [sample(ancient, cpu: 50)])],
            hosts: [idle, silent], now: now)

        XCTAssertEqual(built.map(\.label), ["idle"],
                       "an idle machine is news; one we haven't heard from is not")
    }

    // MARK: - What each host reports

    func testMemoryIsAPercentageOfThatHostsOwnTotal() {
        // 8 GB used of 64 GB and 4 GB of 8 GB: the big machine is LESS
        // full, and only percent can say so.
        let big = FleetSeries.series(for: stream(UUID(), label: "big", samples: [
            sample(0, cpu: 1, mem: 8192, memTotal: 65536)]), now: now)
        let small = FleetSeries.series(for: stream(UUID(), label: "small", samples: [
            sample(0, cpu: 1, mem: 4096, memTotal: 8192)]), now: now)

        XCTAssertEqual(big.mem?.last ?? -1, 12.5, accuracy: 0.01)
        XCTAssertEqual(small.mem?.last ?? -1, 50, accuracy: 0.01)
    }

    func testNoGPUReportedMeansNoGPUSeries() {
        let s = FleetSeries.series(for: stream(UUID(), label: "a", samples: [
            sample(0, cpu: 50)]), now: now)
        XCTAssertNil(s.gpu, "a host without a GPU must not draw an empty GPU chart")
        XCTAssertNil(s.mem)
    }

    func testPeakIsTheMaxOfCPUAndGPU() {
        let s = FleetSeries.series(for: stream(UUID(), label: "a", samples: [
            sample(100, cpu: 30, gpu: 95), sample(0, cpu: 40, gpu: 10)]), now: now)
        XCTAssertEqual(s.peak, 95, accuracy: 0.001,
                       "a GPU-bound host is busy even when its CPU is idle")
    }

    // MARK: - Selection

    func testBusiestHostsWinTheLimitedSlots() {
        var hosts: [HostConfig] = []
        var streams: [HostCPUStream] = []
        for (i, load) in [10.0, 90.0, 50.0, 70.0, 30.0, 20.0].enumerated() {
            let h = host("h\(i)")
            hosts.append(h)
            streams.append(stream(h.id, label: h.label, samples: [sample(0, cpu: load)]))
        }
        let built = FleetSeries.build(streams: streams, hosts: hosts, now: now, limit: 3)
        XCTAssertEqual(built.map(\.label), ["h1", "h3", "h2"])
    }

    func testOrderIsStableWhenEveryHostIsIdle() {
        // Overnight, every peak is 0. Rows must not shuffle frame to frame.
        let hosts = ["zeta", "alpha", "mid"].map { host($0) }
        let streams = hosts.map { stream($0.id, label: $0.label, samples: [sample(0, cpu: 0)]) }
        let built = FleetSeries.build(streams: streams, hosts: hosts, now: now)
        XCTAssertEqual(built.map(\.label), ["alpha", "mid", "zeta"])
    }

    func testTwoEntriesForTheSameMachineCollapseToOneRow() {
        // Same box, two host entries (a common setup: different default
        // tmux session). Drawing it twice would waste a slot and lie
        // about how many machines are busy.
        let a = host("build-01"); let b = host("build-01")
        let built = FleetSeries.build(
            streams: [stream(a.id, label: "build (api)", samples: [sample(0, cpu: 20)]),
                      stream(b.id, label: "build (web)", samples: [sample(0, cpu: 80)])],
            hosts: [a, b], now: now)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.peak, 80, "keep whichever entry has more to show")
    }

    func testDifferentPortIsADifferentMachine() {
        let a = host("gateway", port: 22)
        let b = host("gateway", port: 2222)
        let built = FleetSeries.build(
            streams: [stream(a.id, label: "a", samples: [sample(0, cpu: 20)]),
                      stream(b.id, label: "b", samples: [sample(0, cpu: 30)])],
            hosts: [a, b], now: now)
        XCTAssertEqual(built.count, 2)
    }

    func testLocalhostIsExcluded() {
        let local = host("localhost", local: true)
        let remote = host("remote")
        let built = FleetSeries.build(
            streams: [stream(local.id, label: "localhost", samples: [sample(0, cpu: 99)]),
                      stream(remote.id, label: "remote", samples: [sample(0, cpu: 5)])],
            hosts: [local, remote], now: now)
        XCTAssertEqual(built.map(\.label), ["remote"])
    }

    func testStreamWithNoMatchingHostConfigIsIgnored() {
        // A removed host can linger in the stream file; it has no SSH
        // identity to dedupe on and no way to be labelled honestly.
        let built = FleetSeries.build(
            streams: [stream(UUID(), label: "ghost", samples: [sample(0, cpu: 50)])],
            hosts: [], now: now)
        XCTAssertTrue(built.isEmpty)
    }

    // MARK: - Merging

    func testMergedTakesTheMaxPerColumnNotThePerHostMax() {
        // a peaks early, b peaks late. The merged line must follow
        // whoever is busy AT THAT MOMENT — not flatten to one number.
        let ha = host("a"); let hb = host("b")
        let built = FleetSeries.build(
            streams: [stream(ha.id, label: "a", samples: [sample(400, cpu: 90), sample(0, cpu: 10)]),
                      stream(hb.id, label: "b", samples: [sample(400, cpu: 10), sample(0, cpu: 80)])],
            hosts: [ha, hb], now: now)

        let merged = FleetSeries.mergedMaxCPU(built)
        XCTAssertEqual(merged.last!, 80, accuracy: 0.001, "b is busy now")
        XCTAssertEqual(merged.max()!, 90, accuracy: 0.001, "a was busier earlier")
    }

    func testAGPULessHostDoesNotDragTheFleetGPUDown() {
        let ha = host("a"); let hb = host("b")
        let built = FleetSeries.build(
            streams: [stream(ha.id, label: "a", samples: [sample(0, cpu: 5, gpu: 60)]),
                      stream(hb.id, label: "b", samples: [sample(0, cpu: 5)])],
            hosts: [ha, hb], now: now)

        XCTAssertEqual(FleetSeries.mergedMax(built, \.gpu).last!, 60, accuracy: 0.001)
    }

    func testMergedGPUIsEmptyWhenNobodyHasAGPU() {
        let h = host("a")
        let built = FleetSeries.build(
            streams: [stream(h.id, label: "a", samples: [sample(0, cpu: 5)])],
            hosts: [h], now: now)
        XCTAssertTrue(FleetSeries.mergedMax(built, \.gpu).isEmpty,
                      "an all-zero GPU chart would imply a GPU sitting idle")
    }

    // MARK: - Layout cycle

    func testLayoutCycleReturnsToWhereItStarted() {
        var layout = MonitorLayout.detailed
        for _ in 0..<MonitorLayout.allCases.count { layout = layout.next }
        XCTAssertEqual(layout, .detailed)
    }

    func testLayoutCycleVisitsEveryMode() {
        var seen: Set<MonitorLayout> = []
        var layout = MonitorLayout.detailed
        for _ in 0..<MonitorLayout.allCases.count {
            seen.insert(layout)
            layout = layout.next
        }
        XCTAssertEqual(seen, Set(MonitorLayout.allCases))
    }
}
