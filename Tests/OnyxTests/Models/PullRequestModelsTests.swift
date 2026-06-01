import XCTest
@testable import OnyxLib

final class GitHubRepoSpecParseTests: XCTestCase {

    func test_parse_acceptsCanonicalURL() {
        let spec = GitHubRepoSpec.parse("https://github.com/anthropics/claude-code")
        XCTAssertEqual(spec?.owner, "anthropics")
        XCTAssertEqual(spec?.name, "claude-code")
    }

    func test_parse_dropsTrailingSlash() {
        XCTAssertEqual(GitHubRepoSpec.parse("https://github.com/foo/bar/")?.fullName,
                       "foo/bar")
    }

    func test_parse_dropsDotGit() {
        XCTAssertEqual(GitHubRepoSpec.parse("https://github.com/foo/bar.git")?.fullName,
                       "foo/bar")
    }

    func test_parse_acceptsBareOwnerRepo() {
        // The user can paste just "foo/bar" — most ergonomic form.
        XCTAssertEqual(GitHubRepoSpec.parse("foo/bar")?.fullName, "foo/bar")
    }

    func test_parse_rejectsMalformed() {
        XCTAssertNil(GitHubRepoSpec.parse(""))
        XCTAssertNil(GitHubRepoSpec.parse("https://github.com/onlyowner"))
        XCTAssertNil(GitHubRepoSpec.parse("https://gitlab.com/foo/bar"),
                     "non-github URLs should fail — only github.com is supported")
    }

    func test_parse_ignoresExtraPathSegments() {
        // Pasting a deep link to a PR should still resolve to the repo.
        XCTAssertEqual(GitHubRepoSpec.parse("https://github.com/foo/bar/pull/123")?.fullName,
                       "foo/bar")
    }
}

final class PRMergeStatusMappingTests: XCTestCase {

    func test_cleanIsReady() {
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "CLEAN", mergeable: nil), .ready)
    }

    func test_blockedReportsBlocked() {
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "BLOCKED", mergeable: "MERGEABLE"),
                       .blocked,
                       "branch protection should win over the mergeable bit")
    }

    func test_dirtyIsConflicts() {
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "DIRTY", mergeable: "CONFLICTING"),
                       .conflicts)
    }

    func test_behindIsBehind() {
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "BEHIND", mergeable: nil), .behind)
    }

    func test_unstableIsChecksFailing() {
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "UNSTABLE", mergeable: "MERGEABLE"),
                       .checksFailing)
    }

    func test_unknownFallsBackToMergeable() {
        // GraphQL can return UNKNOWN immediately after PR creation while
        // it's computing — fall back to the simpler mergeable enum.
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: "UNKNOWN", mergeable: "MERGEABLE"),
                       .ready)
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: nil, mergeable: "CONFLICTING"),
                       .conflicts)
        XCTAssertEqual(PRMergeStatus.fromGraphQL(state: nil, mergeable: nil),
                       .unknown)
    }
}
