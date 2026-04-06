import XCTest
@testable import OnyxLib

// MARK: - MonitorManager bucketedCPU Tests

final class MonitorBucketTests: XCTestCase {

    func testBucketedCPU_oneMinuteBuckets_anchorToWallClock() {
        let state = AppState()
        let monitor = MonitorManager(appState: state)
        monitor.useShortInterval = false // use 1-minute buckets

        let calendar = Calendar.current
        let now = Date()
        // Round down to start of current minute
        let currentMinuteStart = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now))!

        // Add samples in the current minute
        let sample1 = MonitorSample(timestamp: currentMinuteStart.addingTimeInterval(5), cpuUsage: 50.0)
        let sample2 = MonitorSample(timestamp: currentMinuteStart.addingTimeInterval(10), cpuUsage: 70.0)

        // Add a sample in the previous minute
        let sample3 = MonitorSample(timestamp: currentMinuteStart.addingTimeInterval(-30), cpuUsage: 30.0)

        monitor.injectSamples([sample3, sample1, sample2])

        let buckets = monitor.bucketedCPU()
        XCTAssertEqual(buckets.count, 60, "Should always return 60 buckets")

        // Last bucket (index 59) = current minute, should average sample1 and sample2
        XCTAssertEqual(buckets[59], 60.0, accuracy: 0.1, "Current minute should average 50 and 70 = 60")

        // Second-to-last bucket (index 58) = previous minute, should be sample3
        XCTAssertEqual(buckets[58], 30.0, accuracy: 0.1, "Previous minute should have the 30% sample")

        // Older buckets should be 0 (no data)
        XCTAssertEqual(buckets[0], 0.0, accuracy: 0.01, "Oldest bucket with no data should be 0")
    }

    func testBucketedCPU_shortInterval_usesDirectValues() {
        let state = AppState()
        let monitor = MonitorManager(appState: state)
        monitor.useShortInterval = true // use 5s direct mode

        let now = Date()
        monitor.injectSamples([
            MonitorSample(timestamp: now.addingTimeInterval(-10), cpuUsage: 25.0),
            MonitorSample(timestamp: now.addingTimeInterval(-5), cpuUsage: 50.0),
            MonitorSample(timestamp: now, cpuUsage: 75.0),
        ])

        let buckets = monitor.bucketedCPU()
        XCTAssertEqual(buckets.count, 60, "Should return 60 buckets")

        // Last 3 values should be our samples, rest should be 0 (padding)
        XCTAssertEqual(buckets[57], 25.0, accuracy: 0.01)
        XCTAssertEqual(buckets[58], 50.0, accuracy: 0.01)
        XCTAssertEqual(buckets[59], 75.0, accuracy: 0.01)
        XCTAssertEqual(buckets[0], 0.0, accuracy: 0.01, "Padding should be 0")
    }

    func testBucketedCPU_noData_returnsEmpty() {
        let state = AppState()
        let monitor = MonitorManager(appState: state)
        monitor.injectSamples([])

        let buckets = monitor.bucketedCPU()
        XCTAssertTrue(buckets.isEmpty, "No samples should return empty array")
    }
}

// MARK: - Per-Host Isolation (ADR-004)

/// Regression tests for per-host state isolation. Earlier MonitorManager
/// kept a single samples array, so switching hosts polluted charts with
/// data from the previously active host. Each host must have its own
/// buffer that survives across host switches.
final class MonitorManagerPerHostIsolationTests: XCTestCase {

    private func makeHost(label: String) -> HostConfig {
        var h = HostConfig(label: label)
        h.id = UUID()
        return h
    }

    private func session(on host: HostConfig) -> TmuxSession {
        TmuxSession(name: "s-\(host.label)", source: .host(hostID: host.id))
    }

    func testSamples_areKeyedByHost() {
        let state = AppState()
        let hostA = makeHost(label: "alpha")
        let hostB = makeHost(label: "beta")
        state.hosts = [hostA, hostB]

        let monitor = MonitorManager(appState: state)

        // Write samples for host A
        state.activeSession = session(on: hostA)
        let samplesA = [MonitorSample(timestamp: Date(), cpuUsage: 10.0)]
        monitor.injectSamples(samplesA)
        XCTAssertEqual(monitor.samples.count, 1)
        XCTAssertEqual(monitor.samples.first?.cpuUsage, 10.0)

        // Switch to host B — should see no samples
        state.activeSession = session(on: hostB)
        XCTAssertEqual(monitor.samples.count, 0,
                       "Host B must not inherit host A's samples")

        // Write samples for host B
        let samplesB = [MonitorSample(timestamp: Date(), cpuUsage: 90.0)]
        monitor.injectSamples(samplesB)
        XCTAssertEqual(monitor.samples.first?.cpuUsage, 90.0)

        // Switch back to host A — original samples still present
        state.activeSession = session(on: hostA)
        XCTAssertEqual(monitor.samples.count, 1,
                       "Host A's samples must survive a host switch round-trip")
        XCTAssertEqual(monitor.samples.first?.cpuUsage, 10.0)
    }

    func testLatestSample_isPerHost() {
        let state = AppState()
        let hostA = makeHost(label: "alpha")
        let hostB = makeHost(label: "beta")
        state.hosts = [hostA, hostB]

        let monitor = MonitorManager(appState: state)

        state.activeSession = session(on: hostA)
        monitor.injectSamples([MonitorSample(timestamp: Date(), cpuUsage: 11.0)])

        state.activeSession = session(on: hostB)
        monitor.injectSamples([MonitorSample(timestamp: Date(), cpuUsage: 22.0)])

        XCTAssertEqual(monitor.latestSample?.cpuUsage, 22.0)

        state.activeSession = session(on: hostA)
        XCTAssertEqual(monitor.latestSample?.cpuUsage, 11.0)
    }

    func testSwitchingHost_doesNotClearOtherHostBuffers() {
        let state = AppState()
        let hosts = (0..<3).map { makeHost(label: "h\($0)") }
        state.hosts = hosts

        let monitor = MonitorManager(appState: state)

        // Inject distinct values on each host
        for (i, h) in hosts.enumerated() {
            state.activeSession = session(on: h)
            monitor.injectSamples([MonitorSample(timestamp: Date(), cpuUsage: Double(i) * 10)])
        }

        // Verify all three buffers are still intact when visited in any order
        for (i, h) in hosts.enumerated().reversed() {
            state.activeSession = session(on: h)
            XCTAssertEqual(monitor.samples.first?.cpuUsage, Double(i) * 10,
                           "Host \(h.label) lost its samples after switching through others")
        }
    }
}

