import XCTest
@testable import OnyxLib

/// Regression tests for Timing.app API parsing. Every bug documented here
/// shipped to production at least once; do not delete without replacing.
///
/// See: bugs fixed in commits referenced by CHANGELOG / ADR history.
final class TimingDataStoreTests: XCTestCase {

    // MARK: - parseReportRows: start_date location

    /// Regression: start_date is a top-level field on each row, NOT nested
    /// inside timespan. Earlier code looked at timespan.start_date and lost
    /// all data.
    func test_parseReport_startDateAtRowLevel() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":3600,"project":{"title":"Work","self":"/projects/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].date, "2026-04-01")
        XCTAssertEqual(rows[0].seconds, 3600)
    }

    /// Fallback path: some older payloads nested start_date inside timespan.
    /// Still supported.
    func test_parseReport_startDateNestedFallback() throws {
        let json = """
        [{"timespan":{"start_date":"2026-04-02"},"duration":1800,"project":{"title":"X","self":"/p/2"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].date, "2026-04-02")
    }

    // MARK: - parseReport: color handling

    /// Regression: Timing returns 8-char RGBA hex like "#6EBF1DFF", not
    /// 6-char RGB. Earlier code stored 8 chars and the UI drew white.
    /// Policy: accept only exactly 6 chars; 8-char values are rejected to
    /// force the palette fallback path.
    func test_parseReport_rejectsEightCharColor() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"X","self":"/p/1","color":"#6EBF1DFF"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].projectColor, "",
                       "8-char RGBA colors must not be stored — fall through to palette fallback")
    }

    func test_parseReport_accepts6CharColor() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"X","self":"/p/1","color":"#6EBF1D"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows[0].projectColor, "6EBF1D")
    }

    func test_parseReport_emptyColorIsEmpty() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"X","self":"/p/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows[0].projectColor, "")
    }

    // MARK: - parseReport: parent shape

    /// Regression: `parent` comes back as an object `{"self": "/projects/N"}`,
    /// not a bare string. Earlier code expected a string and all hierarchy
    /// was lost.
    func test_parseReport_parentAsObject() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"Child","self":"/p/2","parent":{"self":"/p/1"}}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows[0].parentRef, "/p/1")
    }

    /// Both shapes must work — older payloads send a string ref.
    func test_parseReport_parentAsString() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"Child","self":"/p/2","parent":"/p/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows[0].parentRef, "/p/1")
    }

    func test_parseReport_noParent() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":100,"project":{"title":"Top","self":"/p/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertNil(rows[0].parentRef)
    }

    // MARK: - parseReport: filtering

    func test_parseReport_filtersZeroDuration() throws {
        let json = """
        [
          {"start_date":"2026-04-01","duration":0,"project":{"title":"X","self":"/p/1"}},
          {"start_date":"2026-04-01","duration":60,"project":{"title":"Y","self":"/p/2"}}
        ]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].projectTitle, "Y")
    }

    func test_parseReport_filtersMissingStartDate() throws {
        let json = """
        [
          {"duration":100,"project":{"title":"X","self":"/p/1"}},
          {"start_date":"2026-04-01","duration":60,"project":{"title":"Y","self":"/p/2"}}
        ]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].projectTitle, "Y")
    }

    func test_parseReport_integerDuration() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":120,"project":{"title":"X","self":"/p/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows[0].seconds, 120)
    }

    // MARK: - parseReport: envelope shapes

    /// Timing API sometimes returns a bare array, sometimes a {"data": [...]}
    /// envelope. Both must parse.
    func test_parseReport_bareArray() throws {
        let json = """
        [{"start_date":"2026-04-01","duration":60,"project":{"title":"X","self":"/p/1"}}]
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
    }

    func test_parseReport_dataEnvelope() throws {
        let json = """
        {"data":[{"start_date":"2026-04-01","duration":60,"project":{"title":"X","self":"/p/1"}}]}
        """.data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(json))
        XCTAssertEqual(rows.count, 1)
    }

    func test_parseReport_invalidJSONReturnsNil() {
        let junk = "not json".data(using: .utf8)!
        XCTAssertNil(TimingDataStore.parseReportRows(junk))
    }

    func test_parseReport_emptyArrayReturnsEmpty() throws {
        let empty = "[]".data(using: .utf8)!
        let rows = try XCTUnwrap(TimingDataStore.parseReportRows(empty))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - flattenProjects

    func test_flattenProjects_respectsDepth() {
        let projects: [[String: Any]] = [
            [
                "self": "/p/1", "title": "Root", "color": "#FF0000",
                "title_chain": ["Root"],
                "children": [
                    ["self": "/p/2", "title": "Child", "color": "#00FF00", "title_chain": ["Root", "Child"]]
                ]
            ]
        ]
        var out: [TimingProject] = []
        TimingDataStore.flattenProjects(projects, depth: 0, into: &out)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].depth, 0)
        XCTAssertEqual(out[0].title, "Root")
        XCTAssertEqual(out[1].depth, 1)
        XCTAssertEqual(out[1].title, "Child")
    }

    /// flattenProjects must also truncate 8-char RGBA colors.
    func test_flattenProjects_truncatesEightCharColor() {
        let projects: [[String: Any]] = [
            ["self": "/p/1", "title": "X", "color": "#AABBCCDD", "title_chain": ["X"]]
        ]
        var out: [TimingProject] = []
        TimingDataStore.flattenProjects(projects, depth: 0, into: &out)
        XCTAssertEqual(out.count, 1)
        // Current behavior: prefix(6) → "AABBCC"
        XCTAssertEqual(out[0].color, "AABBCC")
    }

    /// titleChain must fall back to [title] if the API omits it.
    func test_flattenProjects_titleChainFallback() {
        let projects: [[String: Any]] = [
            ["self": "/p/1", "title": "Solo", "color": "#FFFFFF"]
        ]
        var out: [TimingProject] = []
        TimingDataStore.flattenProjects(projects, depth: 0, into: &out)
        XCTAssertEqual(out[0].titleChain, ["Solo"])
    }
}
