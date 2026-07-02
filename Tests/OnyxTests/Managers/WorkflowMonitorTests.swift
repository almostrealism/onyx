import XCTest
@testable import OnyxLib

/// Regression tests for the duplicate-id crash: adding a pipeline URL that
/// parsed to an already-tracked id made WorkflowMonitor build a Dictionary via
/// `uniqueKeysWithValues`, which TRAPS on duplicate keys — crashing the app on
/// every launch once the URL was persisted. `WorkflowMonitor.ordered` must
/// tolerate duplicates.
final class WorkflowMonitorTests: XCTestCase {

    private func status(for spec: PipelineSpec, failed: Int = 0) -> PipelineStatus {
        PipelineStatus(spec: spec, runNumber: nil, runURL: nil, headBranch: nil,
                       title: nil, succeeded: 1, inProgress: 0, queued: 0,
                       skipped: 0, failed: failed, overall: .success, lastUpdated: Date())
    }

    func test_ordered_toleratesDuplicateIds_noCrash() throws {
        // Two identical URLs → two specs with the same id.
        let url = "https://github.com/acme/app/actions/workflows/ci.yml"
        let spec = try XCTUnwrap(PipelineSpec.parse(url))
        let specs = [spec, spec]                       // duplicate
        let collected = [status(for: spec), status(for: spec, failed: 3)]  // duplicate ids

        // Must not trap, and must collapse to a single row.
        let result = WorkflowMonitor.ordered(specs: specs, collected: collected)
        XCTAssertEqual(result.count, 1, "duplicate specs collapse to one row")
        XCTAssertEqual(result.first?.id, spec.id)
    }

    func test_ordered_preservesSpecOrder() throws {
        let a = try XCTUnwrap(PipelineSpec.parse("https://github.com/acme/a/actions/workflows/ci.yml"))
        let b = try XCTUnwrap(PipelineSpec.parse("https://github.com/acme/b/actions/workflows/ci.yml"))
        // collected arrives out of order; output should follow specs order.
        let result = WorkflowMonitor.ordered(specs: [a, b], collected: [status(for: b), status(for: a)])
        XCTAssertEqual(result.map(\.id), [a.id, b.id])
    }

    func test_ordered_dropsSpecsWithNoStatus() throws {
        let a = try XCTUnwrap(PipelineSpec.parse("https://github.com/acme/a/actions/workflows/ci.yml"))
        let b = try XCTUnwrap(PipelineSpec.parse("https://github.com/acme/b/actions/workflows/ci.yml"))
        // Only `a` fetched successfully.
        let result = WorkflowMonitor.ordered(specs: [a, b], collected: [status(for: a)])
        XCTAssertEqual(result.map(\.id), [a.id])
    }
}
