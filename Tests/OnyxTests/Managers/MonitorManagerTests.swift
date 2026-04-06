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

