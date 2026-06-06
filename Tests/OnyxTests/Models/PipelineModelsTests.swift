import XCTest
@testable import OnyxLib

final class PipelineSpecParseTests: XCTestCase {

    func test_workflowURL_isWorkflowTarget_onDefaultBranch() {
        let s = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml")
        XCTAssertEqual(s?.owner, "foo")
        XCTAssertEqual(s?.repo, "bar")
        if case .workflow(let file, let branch) = s?.target {
            XCTAssertEqual(file, "ci.yml")
            XCTAssertNil(branch, "default branch when no query param present")
        } else { XCTFail("expected .workflow") }
    }

    func test_workflowURL_withBranchQuery() {
        let s = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml?branch=feature-x")
        if case .workflow(_, let branch) = s?.target {
            XCTAssertEqual(branch, "feature-x")
        } else { XCTFail() }
    }

    func test_workflowURL_withGithubStyleQueryParam() {
        // GitHub's own actions UI builds URLs like
        // ?query=branch%3Afeature-x — we recognize that form too.
        let s = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml?query=branch%3Afeature-x")
        if case .workflow(_, let branch) = s?.target {
            XCTAssertEqual(branch, "feature-x")
        } else { XCTFail() }
    }

    func test_runURL_isRunTarget() {
        let s = PipelineSpec.parse("https://github.com/foo/bar/actions/runs/123456")
        if case .run(let id) = s?.target {
            XCTAssertEqual(id, 123456)
        } else { XCTFail() }
    }

    func test_rejectsNonGithubHost() {
        XCTAssertNil(PipelineSpec.parse("https://gitlab.com/foo/bar/actions/workflows/ci.yml"))
        XCTAssertNil(PipelineSpec.parse("https://github.example.com/foo/bar/actions/workflows/ci.yml"))
    }

    func test_rejectsMalformed() {
        XCTAssertNil(PipelineSpec.parse(""))
        XCTAssertNil(PipelineSpec.parse("https://github.com/foo"))
        XCTAssertNil(PipelineSpec.parse("https://github.com/foo/bar/actions/runs/notanint"))
    }

    func test_displayName_includesBranchWhenNotDefault() {
        let main = PipelineSpec(url: "", owner: "x", repo: "y",
                                target: .workflow(file: "ci.yml", branch: "main"))
        let feature = PipelineSpec(url: "", owner: "x", repo: "y",
                                   target: .workflow(file: "ci.yml", branch: "feature-x"))
        XCTAssertFalse(main.displayName.contains("(main)"),
                       "main/master suppressed because that's the implicit default")
        XCTAssertTrue(feature.displayName.contains("(feature-x)"))
    }

    func test_idIsStableAcrossEqualSpecs() {
        let a = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml")!
        let b = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml")!
        XCTAssertEqual(a.id, b.id)
    }
}
