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

// MARK: - CPU diagnostic tests
//
// When some remote hosts produce a `top` output our regex doesn't recognize,
// parse() succeeds but cpuUsage is nil and the chart silently disappears.
// cpuDiagnostic(from:) provides the message that gets shown in place of the
// chart so the user can see WHY it isn't rendering.

final class MonitorCPUDiagnosticTests: XCTestCase {

    func testCpuDiagnostic_missingCpuSection() {
        let output = """
        UPTIME
        ---
         12:34:56 up 1 day, load average: 0.10, 0.20, 0.30
        ---
        MEM
        ---
        Mem:  16000  4000  12000
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("no CPU section"),
                      "Expected 'no CPU section' message, got: \(msg)")
    }

    func testCpuDiagnostic_emptyCpuSection() {
        let output = "CPU\n---\n\n   \n---\nGPU\n---\nN/A"
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("empty") || msg.contains("no output"),
                      "Expected empty-section message, got: \(msg)")
    }

    func testCpuDiagnostic_unrecognizedTopFormat() {
        let output = "CPU\n---\nMem: 12345K used, 67890K free, 0K shrd\nLoad average: 0.1 0.2 0.3\n---\nGPU\n---\nN/A"
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("Unrecognized"),
                      "Expected 'Unrecognized' message, got: \(msg)")
        XCTAssertTrue(msg.contains("Mem:"),
                      "Expected sample lines in message, got: \(msg)")
    }

    func testCpuDiagnostic_truncatesLongLine() {
        let longLine = String(repeating: "x", count: 300)
        let output = "CPU\n---\n\(longLine)\n---\n"
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.hasSuffix("…"),
                      "Expected ellipsis on truncated sample, got: \(msg)")
        XCTAssertLessThan(msg.count, 200,
                          "Diagnostic message should be capped, got \(msg.count) chars")
    }

    func testCpuDiagnostic_reportsLastSectionWhenMultipleExist() {
        // Simulates verbose-mode echo: multiple `---CPU---` markers appear
        // because the script source contains them and is also echoed. The
        // diagnostic should show the LAST section's content (most likely
        // real top output if any) and note the section count.
        let output = """
        ---CPU---
        ; CPU_OUT=$(top -bn1); if [ -n "$CPU_OUT" ];
        ---MEM---
        ;
        ---CPU---
        REAL_LINE_FROM_TOP_OUTPUT
        ---MEM---
        Mem: 16000 4000 12000
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("REAL_LINE_FROM_TOP_OUTPUT"),
                      "Expected last-section content, got: \(msg)")
        XCTAssertTrue(msg.contains("2 sections"),
                      "Expected section count note, got: \(msg)")
    }

    func testScanCpuUsage_busyboxFormat() {
        let line = "CPU:   3% usr   1% sys   0% nic  96% idle   0% io   0% irq   0% sirq"
        let usage = MonitorManager.scanCpuUsage(in: [line])
        XCTAssertEqual(usage ?? -1, 100.0 - 96.0, accuracy: 0.01,
                       "Expected busybox CPU line to parse, got: \(String(describing: usage))")
    }

    func testScanCpuUsage_macOSFormat() {
        let line = "CPU usage: 19.46% user, 7.62% sys, 73.47% idle"
        let usage = MonitorManager.scanCpuUsage(in: [line])
        XCTAssertEqual(usage ?? -1, 100.0 - 73.47, accuracy: 0.01)
    }

    func testScanCpuUsage_linuxFormat() {
        let line = "%Cpu(s):  3.5 us,  1.2 sy,  0.0 ni, 95.3 id,  0.0 wa"
        let usage = MonitorManager.scanCpuUsage(in: [line])
        XCTAssertEqual(usage ?? -1, 100.0 - 95.3, accuracy: 0.01)
    }

    func testScanCpuUsage_linuxAltFormat() {
        // No space between % and id ("95.3%id")
        let line = "Cpu(s):  3.5%us,  1.2%sy,  0.0%ni, 95.3%id,  0.0%wa"
        let usage = MonitorManager.scanCpuUsage(in: [line])
        XCTAssertEqual(usage ?? -1, 100.0 - 95.3, accuracy: 0.01)
    }

    func testScanCpuUsage_skipsLineWithoutCpuKeyword() {
        // Line has digits and "idle" but no "cpu" — must not false-match.
        let line = "Load: 95.3 idle minutes since boot"
        XCTAssertNil(MonitorManager.scanCpuUsage(in: [line]))
    }

    func testParse_fallsBackToFullOutputWhenSectionContaminated() {
        // Simulates a remote where `set -v` is on: the script source is
        // echoed before each command, so the CPU section starts with junk.
        // The real `top` line is still somewhere in the stream, so the
        // full-output fallback should pick it up.
        let output = """
        ---UPTIME---
         12:00:00 up 1 day, load average: 0.10, 0.20, 0.30
        ---CPU---
        echo "---CPU---"; CPU_OUT=$(top -bn1 ...); if [ -n "$CPU_OUT" ];
        then echo "$CPU_OUT"; else top -l1 -s0 | head -10; fi;
        top - 12:00:00 up 1 day, 0 users, load average: 0.1
        Tasks: 100 total
        %Cpu(s):  3.5 us,  1.2 sy,  0.0 ni, 95.3 id,  0.0 wa
        ---MEM---
        Mem: 16000 4000 12000
        ---GPU---
        N/A
        """
        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        XCTAssertNotNil(sample?.cpuUsage,
                        "Expected fallback scan to find %Cpu(s) line in full output")
        if let cpu = sample?.cpuUsage {
            XCTAssertEqual(cpu, 100.0 - 95.3, accuracy: 0.01)
        }
    }

    func testParse_unrecognizedTopProducesNilCpuUsage() {
        // This is the actual silent-failure case: parse succeeds with a sample
        // but cpuUsage is nil because no recognized line matched.
        let output = "CPU\n---\nMem: 12345K used, 67890K free\nLoad: 0.1 0.2 0.3\n---\n"
        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample, "parse should still return a sample on unrecognized CPU output")
        XCTAssertNil(sample?.cpuUsage, "cpuUsage should be nil when no recognized format matches")
    }
}
