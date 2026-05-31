import XCTest
@testable import OnyxLib

/// Tests for the adaptive CPU/memory formatters used by the container list
/// in the monitor overlay. Goal of the format: every output is short
/// enough to fit its column, regardless of how busy the container is or
/// how much memory it owns — so the row layout never wraps to two lines.
final class MonitorCompactFormattingTests: XCTestCase {

    // MARK: - CPU

    func test_compactCPU_smallValues_keepTwoDecimals() {
        XCTAssertEqual(monitorCompactCPU("0.05%"), "0.05%")
        XCTAssertEqual(monitorCompactCPU("9.99%"), "9.99%")
    }

    func test_compactCPU_midValues_dropToOneDecimal() {
        // 10..99.99 → one decimal, so we never spend a char on a fixed
        // ".x0" form that wastes column space.
        XCTAssertEqual(monitorCompactCPU("12.34%"), "12.3%")
        XCTAssertEqual(monitorCompactCPU("99.99%"), "100.0%")  // rounds across
    }

    func test_compactCPU_highValues_dropDecimals() {
        XCTAssertEqual(monitorCompactCPU("150.00%"), "150%")
        XCTAssertEqual(monitorCompactCPU("999.99%"), "1000%")
    }

    func test_compactCPU_unparseableFallsBackToInput() {
        // If we can't make sense of the value, render it verbatim
        // (better to show something weird than a misleading number).
        XCTAssertEqual(monitorCompactCPU("--"), "--")
        XCTAssertEqual(monitorCompactCPU(""), "")
    }

    func test_compactCPU_neverExceedsFiveCharacters() {
        // Hard contract: column is 55px at 11pt monospace — anything
        // ≤ 5 chars is comfortable, 6 is the truncation/scale fallback.
        // Sweep all realistic values and check.
        for v in stride(from: 0.0, through: 999.0, by: 0.37) {
            let s = monitorCompactCPU("\(v)%")
            XCTAssertLessThanOrEqual(s.count, 6,
                                     "CPU value \(v) formatted as \(s.debugDescription) — must stay ≤ 6 chars")
        }
    }

    // MARK: - Memory

    func test_shortMem_typicalPair() {
        // "12.34MiB / 7.656GiB" — common idle case.
        XCTAssertEqual(monitorShortMem("12.34MiB / 7.656GiB"), "12.3M/7.7G")
    }

    func test_shortMem_largeMemDropsDecimals() {
        // High-memory containers: at >= 100 we drop to whole numbers.
        XCTAssertEqual(monitorShortMem("888.5MiB / 256.0GiB"), "888M/256G")
    }

    func test_shortMem_terabytesWhenOverflowing() {
        // "9999.0GiB" rolls over into the T format so we never produce
        // a 5-digit value that overflows the column.
        let s = monitorShortMem("9999.0GiB / 10240.0GiB")
        // Both sides should be ≤ 5 chars after compaction.
        for part in s.components(separatedBy: "/") {
            XCTAssertLessThanOrEqual(part.count, 5,
                                     "each side must be ≤ 5 chars; got: \(part)")
        }
    }

    func test_shortMem_handlesPlainBSuffix() {
        // docker stats can emit "0B / 1.5GiB" for a container with nothing
        // touched yet — make sure the B form is recognized.
        XCTAssertEqual(monitorShortMem("0B / 1.5GiB"), "0.00B/1.5G")
    }

    func test_shortMem_handlesNonIECSuffixes() {
        // Some sources emit MB/GB instead of MiB/GiB; treat both the same.
        XCTAssertEqual(monitorShortMem("128MB / 8GB"), "128M/8.0G")
    }

    func test_shortMem_unrecognizedSuffixPassesThrough() {
        // Don't trash unfamiliar formats — the user can at least read
        // the raw value rather than seeing a garbled rewrite.
        XCTAssertEqual(monitorShortMem("weird / value"), "weird/value")
    }

    func test_shortMem_neverExceedsElevenCharacters() {
        // Column is 80px ≈ 11 chars at 11pt monospace. Sweep a range
        // of mem totals and check the result fits.
        let totals = ["1.5GiB", "16GiB", "64GiB", "256GiB", "1024GiB"]
        for used in stride(from: 0.0, through: 1000.0, by: 17.3) {
            for total in totals {
                let s = monitorShortMem("\(used)MiB / \(total)")
                XCTAssertLessThanOrEqual(s.count, 11,
                                         "mem \(used)MiB / \(total) → \(s.debugDescription) must stay ≤ 11 chars")
            }
        }
    }
}
