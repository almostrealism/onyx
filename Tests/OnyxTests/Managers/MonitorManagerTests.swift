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

    func testCpuDiagnostic_executionProofIsNotSpoofableByVerboseEcho() {
        // When the remote shell is in noexec+verbose mode (set -nv), it
        // prints the script source without running anything. The script
        // source contains the literal text `echo "---ONYX-OK-$((1+1))---"`,
        // so a naive marker check (e.g. searching for "ONYX-OK") would
        // find it and falsely conclude the script ran. The execution
        // proof must require shell expansion — only an actually-running
        // shell emits the literal "2".
        let output = """
        ; CPU_OUT=$(top -bn1); ...; echo "---ONYX-OK-$((1+1))---"
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("did not execute"),
                      "Expected script-didn't-run message even when source contains the marker text, got: \(msg)")
    }

    func testCpuDiagnostic_scriptDidNotExecute() {
        // No execution-proof marker means the remote echoed the script
        // source instead of running it. This is the most common failure
        // we've observed in the wild.
        let output = """
        ---UPTIME---
        ; uptime; echo "---CPU---"; CPU_OUT=$(top -bn1); ...; echo "---MEM---"; ...
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("did not execute"),
                      "Expected script-didn't-run message, got: \(msg)")
    }

    func testCpuDiagnostic_missingCpuSection() {
        let output = """
        UPTIME
        ---
         12:34:56 up 1 day, load average: 0.10, 0.20, 0.30
        ---
        MEM
        ---
        Mem:  16000  4000  12000
        ---ONYX-OK-2---
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("no CPU section"),
                      "Expected 'no CPU section' message, got: \(msg)")
    }

    func testCpuDiagnostic_emptyCpuSection() {
        let output = "CPU\n---\n\n   \n---\nGPU\n---\nN/A\n---ONYX-OK-2---"
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("empty") || msg.contains("no output"),
                      "Expected empty-section message, got: \(msg)")
    }

    func testCpuDiagnostic_unrecognizedTopFormat() {
        let output = "CPU\n---\nMem: 12345K used, 67890K free, 0K shrd\nLoad average: 0.1 0.2 0.3\n---\nGPU\n---\nN/A\n---ONYX-OK-2---"
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("Unrecognized"),
                      "Expected 'Unrecognized' message, got: \(msg)")
        XCTAssertTrue(msg.contains("Mem:"),
                      "Expected sample lines in message, got: \(msg)")
    }

    func testCpuDiagnostic_truncatesLongLine() {
        let longLine = String(repeating: "x", count: 300)
        let output = "CPU\n---\n\(longLine)\n---\n---ONYX-OK-2---"
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
        ---ONYX-OK-2---
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

// MARK: - Parser resilience to noisy SSH output
//
// `ssh -tt` adds CR-LF endings, banners, and shell-prompt artifacts.
// These tests pin down that the parser still extracts CPU/mem/etc.
// when the real top output is buried in noise — the kinds of contamination
// we observed during the long debug session that motivated RemoteScript.

final class MonitorParserResilienceTests: XCTestCase {

    func testParse_extractsCpuFromOutputWithMOTDBanner() {
        // Many remote hosts print an MOTD before our markers. The parser
        // must ignore everything outside the section delimiters.
        let output = """
        ============================================
         Welcome to host42 — last login: yesterday
         Unauthorized access prohibited
        ============================================

        ---UPTIME---
         12:34:56 up 1 day, load average: 0.10, 0.20, 0.30
        ---CPU---
        %Cpu(s):  3.5 us,  1.2 sy,  0.0 ni, 95.3 id,  0.0 wa
        ---MEM---
        Mem: 16000 4000 12000
        ---GPU---
        N/A
        """
        let sample = MonitorManager.parse(output: output)
        XCTAssertEqual(sample?.cpuUsage ?? -1, 100.0 - 95.3, accuracy: 0.01,
                       "MOTD banner before markers should not break parsing")
        XCTAssertEqual(sample?.loadAvg1 ?? -1, 0.10, accuracy: 0.001,
                       "load average should still parse with banner present")
    }

    func testParse_extractsCpuWhenScriptSourceContaminatesSection() {
        // Verbose-mode echo prepends the script source to each section.
        // The parser falls back to scanning the entire output, so the
        // real top line is found even when section[0] is junk.
        let output = """
        ---UPTIME---
        ; uptime; echo "---CPU---"; CPU_OUT=$(top -bn1)...
         12:00:00 up 1 day, load average: 0.10, 0.20, 0.30
        ---CPU---
        ; CPU_OUT=$(top -bn1)...; if [ -n "$CPU_OUT" ];...
        %Cpu(s):  2.0 us,  1.0 sy,  0.0 ni, 97.0 id,  0.0 wa
        ---MEM---
        Mem: 8000 2000 6000
        ---GPU---
        N/A
        """
        let sample = MonitorManager.parse(output: output)
        XCTAssertEqual(sample?.cpuUsage ?? -1, 100.0 - 97.0, accuracy: 0.01,
                       "real %Cpu line should still be found when script source pollutes the section")
    }

    func testParse_handlesShellPromptInOutput() {
        // If `stty -echo` fails or isn't honored, prompts may appear.
        // They shouldn't break section parsing.
        let output = """
        $ ---UPTIME---
         12:00:00 up 5 days, load average: 1.00, 1.50, 2.00
        $ ---CPU---
        %Cpu(s):  10.0 us,  5.0 sy,  0.0 ni, 85.0 id
        $ ---MEM---
        Mem: 16000 8000 8000
        $ ---GPU---
        N/A
        """
        let sample = MonitorManager.parse(output: output)
        XCTAssertEqual(sample?.cpuUsage ?? -1, 100.0 - 85.0, accuracy: 0.01,
                       "shell prompts before markers should not break parsing")
    }

    func testRemoteScript_cleanedOutputIsParseableAfterTTYStrip() {
        // End-to-end: an output with CR-LF endings (as ssh -tt produces)
        // gets cleaned by RemoteScript and parsed correctly.
        let raw = "---UPTIME---\r\n 12:00:00 up 1 day, load average: 0.5, 0.5, 0.5\r\n---CPU---\r\n%Cpu(s):  3.0 us, 1.0 sy, 0.0 ni, 96.0 id\r\n---MEM---\r\nMem: 16000 4000 12000\r\n---GPU---\r\nN/A\r\n---ONYX-OK-2---\r\n"
        let cleaned = RemoteScript.cleanedOutput(raw)
        XCTAssertFalse(cleaned.contains("\r"), "cleaned output should have no CR")
        let sample = MonitorManager.parse(output: cleaned)
        XCTAssertEqual(sample?.cpuUsage ?? -1, 100.0 - 96.0, accuracy: 0.01,
                       "parser should work on cleaned ssh -tt output")
    }

    func testCpuDiagnostic_recognizesNoexecBeforeUnrecognizedFormat() {
        // The "did not execute" branch must come BEFORE the "unrecognized
        // format" branch. Otherwise we'd say "look at the top output we
        // can't parse" when there is no top output, only echoed source.
        let output = """
        set +vx 2>/dev/null
        PATH=...
        echo "---UPTIME---"; uptime; echo "---CPU---"; ...
        echo "---ONYX-OK-$((1+1))---"
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertTrue(msg.contains("did not execute"),
                      "noexec must be diagnosed first; got: \(msg)")
    }

    func testCpuDiagnostic_unrecognizedFormatOnlyWhenScriptActuallyRan() {
        // If the marker IS present, the script ran; any failure to extract
        // CPU is a parse-format issue, not a noexec issue.
        let output = """
        ---UPTIME---
        12:00:00 up
        ---CPU---
        SomeWeirdHeader: 12345 with no recognized fields
        ---MEM---
        ---GPU---
        ---ONYX-OK-2---
        """
        let msg = MonitorManager.cpuDiagnostic(from: output)
        XCTAssertFalse(msg.contains("did not execute"),
                       "should not claim noexec when marker is present; got: \(msg)")
        XCTAssertTrue(msg.contains("Unrecognized") || msg.contains("empty") || msg.contains("no output"),
                      "should report unrecognized/empty top output; got: \(msg)")
    }
}
