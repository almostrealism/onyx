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
        // NOTE: a bare owner used to be malformed. It now means "every
        // repo this owner has" — see testBareOwnerIsAnOwnerWideEntry.
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

/// Bare owners and orgs — one entry instead of a hand-maintained list.
final class GitHubOwnerWideParseTests: XCTestCase {

    // MARK: - Owner-wide entries

    /// The point of the feature: name an org once instead of listing its
    /// repos and then missing the one created yesterday.
    func testBareOwnerIsAnOwnerWideEntry() {
        let spec = GitHubRepoSpec.parse("almostrealism")
        XCTAssertEqual(spec?.owner, "almostrealism")
        XCTAssertTrue(spec?.isOwnerWide ?? false)
        XCTAssertEqual(spec?.fullName, "almostrealism",
                       "an owner entry shouldn't render as almostrealism/")
    }

    func testOwnerURLIsAlsoOwnerWide() {
        XCTAssertTrue(GitHubRepoSpec.parse("https://github.com/almostrealism")?.isOwnerWide ?? false)
        XCTAssertTrue(GitHubRepoSpec.parse("github.com/almostrealism/")?.isOwnerWide ?? false)
    }

    func testSingleRepoIsStillASingleRepo() {
        let spec = GitHubRepoSpec.parse("almostrealism/common")
        XCTAssertFalse(spec?.isOwnerWide ?? true)
        XCTAssertEqual(spec?.fullName, "almostrealism/common")
    }

    /// A bare owner must not swallow another forge's host — "gitlab.com"
    /// is one segment too, and treating it as a GitHub org would send
    /// every GitLab entry to the wrong API.
    func testOtherForgeHostIsStillRejected() {
        XCTAssertNil(GitHubRepoSpec.parse("gitlab.com"))
        XCTAssertNil(GitHubRepoSpec.parse("gitlab.com/fivn/thing"))
        XCTAssertNil(GitHubRepoSpec.parse("https://gitlab.com/fivn"))
    }

    func testEmptyInputIsStillRejected() {
        XCTAssertNil(GitHubRepoSpec.parse(""))
        XCTAssertNil(GitHubRepoSpec.parse("   "))
    }

    func testTrailingSlashIsJustTheOwner() {
        // Someone pasting from the address bar gets a trailing slash;
        // that's the owner, not a repo with no name.
        XCTAssertTrue(GitHubRepoSpec.parse("owner/")?.isOwnerWide ?? false)
    }
}
