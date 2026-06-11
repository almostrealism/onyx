import XCTest
@testable import OnyxLib

// MARK: - GitLab pipeline URL parsing (via the shared PipelineSpec.parse)

final class GitLabPipelineParseTests: XCTestCase {

    func test_pipelineURL_isGitLabPipelineTarget() {
        let spec = PipelineSpec.parse("https://gitlab.com/group/project/-/pipelines/123456")
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.provider, .gitlab)
        XCTAssertEqual(spec?.path, "group/project")
        XCTAssertEqual(spec?.target, .pipeline(id: 123456))
        XCTAssertEqual(spec?.displayName, "pipeline #123456")
    }

    func test_pipelineURL_multiSegmentGroupPath() {
        let spec = PipelineSpec.parse("https://gitlab.com/group/sub/project/-/pipelines/42")
        XCTAssertEqual(spec?.provider, .gitlab)
        XCTAssertEqual(spec?.path, "group/sub/project")
        XCTAssertEqual(spec?.target, .pipeline(id: 42))
        // owner = first segment, repo = last segment (for display).
        XCTAssertEqual(spec?.owner, "group")
        XCTAssertEqual(spec?.repo, "project")
    }

    func test_pipelineURL_bareHostAccepted() {
        let spec = PipelineSpec.parse("gitlab.com/g/p/-/pipelines/7")
        XCTAssertEqual(spec?.provider, .gitlab)
        XCTAssertEqual(spec?.target, .pipeline(id: 7))
    }

    func test_pipelineURL_stripsQuery() {
        let spec = PipelineSpec.parse("https://gitlab.com/g/p/-/pipelines/9?ref=main")
        XCTAssertEqual(spec?.target, .pipeline(id: 9))
    }

    func test_rejectsGitLabNonPipelineURL() {
        // A merge-request URL is not a pipeline.
        XCTAssertNil(PipelineSpec.parse("https://gitlab.com/g/p/-/merge_requests/3"))
        // No pipeline id.
        XCTAssertNil(PipelineSpec.parse("https://gitlab.com/g/p/-/pipelines"))
        // Non-integer id.
        XCTAssertNil(PipelineSpec.parse("https://gitlab.com/g/p/-/pipelines/abc"))
    }

    func test_id_isProviderQualifiedAndStable() {
        let a = PipelineSpec.parse("https://gitlab.com/g/p/-/pipelines/5")
        let b = PipelineSpec.parse("gitlab.com/g/p/-/pipelines/5")
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertEqual(a?.id, "gitlab:g/p/pipeline/5")
        // GitHub run #5 in a same-named path must not collide.
        let gh = PipelineSpec.parse("https://github.com/g/p/actions/runs/5")
        XCTAssertNotEqual(a?.id, gh?.id)
    }

    func test_encodedPath_onlyEscapesSlash() {
        let spec = PipelineSpec.parse("https://gitlab.com/my-group/my-project/-/pipelines/1")
        // Hyphens stay; only the slash is escaped (GitLab's documented form).
        XCTAssertEqual(spec?.encodedPath, "my-group%2Fmy-project")
    }
}

// MARK: - GitHub still parses, tagged as .github

final class PipelineProviderRoutingTests: XCTestCase {

    func test_githubWorkflowURL_isGitHubProvider() {
        let spec = PipelineSpec.parse("https://github.com/foo/bar/actions/workflows/ci.yml")
        XCTAssertEqual(spec?.provider, .github)
        XCTAssertEqual(spec?.path, "foo/bar")
        XCTAssertEqual(spec?.target, .workflow(file: "ci.yml", branch: nil))
    }

    func test_githubRunURL_isGitHubProvider() {
        let spec = PipelineSpec.parse("https://github.com/foo/bar/actions/runs/99")
        XCTAssertEqual(spec?.provider, .github)
        XCTAssertEqual(spec?.target, .run(id: 99))
    }
}

// MARK: - GitLabProjectSpec parsing

final class GitLabProjectSpecParseTests: XCTestCase {

    func test_parse_fullURL() {
        let spec = GitLabProjectSpec.parse("https://gitlab.com/group/project")
        XCTAssertEqual(spec?.path, "group/project")
        XCTAssertEqual(spec?.name, "project")
    }

    func test_parse_barePath() {
        let spec = GitLabProjectSpec.parse("group/project")
        XCTAssertEqual(spec?.path, "group/project")
    }

    func test_parse_multiSegment() {
        let spec = GitLabProjectSpec.parse("gitlab.com/group/sub/project")
        XCTAssertEqual(spec?.path, "group/sub/project")
        XCTAssertEqual(spec?.name, "project")
    }

    func test_parse_trimsDeepLink() {
        let spec = GitLabProjectSpec.parse("https://gitlab.com/group/project/-/merge_requests")
        XCTAssertEqual(spec?.path, "group/project")
    }

    func test_parse_dropsDotGit() {
        let spec = GitLabProjectSpec.parse("https://gitlab.com/group/project.git")
        XCTAssertEqual(spec?.path, "group/project")
    }

    func test_parse_rejectsNonGitLabHost() {
        XCTAssertNil(GitLabProjectSpec.parse("https://github.com/foo/bar"))
        XCTAssertNil(GitLabProjectSpec.parse(""))
        XCTAssertNil(GitLabProjectSpec.parse("single"))
    }

    func test_encodedPath() {
        let spec = GitLabProjectSpec.parse("group/sub/project")
        XCTAssertEqual(spec?.encodedPath, "group%2Fsub%2Fproject")
    }
}

// MARK: - GitLab merge status mapping

final class GitLabMergeStatusMappingTests: XCTestCase {

    func test_mergeable() {
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: "mergeable",
                                                mergeStatus: nil, hasConflicts: false), .ready)
    }

    func test_conflict() {
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: "conflict",
                                                mergeStatus: nil, hasConflicts: true), .conflicts)
    }

    func test_needRebaseIsBehind() {
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: "need_rebase",
                                                mergeStatus: nil, hasConflicts: false), .behind)
    }

    func test_ciStillRunningIsChecksFailing() {
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: "ci_still_running",
                                                mergeStatus: nil, hasConflicts: false), .checksFailing)
    }

    func test_blockedFamily() {
        for s in ["draft_status", "not_approved", "ci_must_pass", "discussions_not_resolved"] {
            XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: s,
                                                    mergeStatus: nil, hasConflicts: false), .blocked,
                           "\(s) should map to .blocked")
        }
    }

    func test_legacyFallback() {
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: nil,
                                                mergeStatus: "can_be_merged", hasConflicts: false), .ready)
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: nil,
                                                mergeStatus: "cannot_be_merged", hasConflicts: true), .conflicts)
        XCTAssertEqual(PRMergeStatus.fromGitLab(detailed: nil,
                                                mergeStatus: "cannot_be_merged", hasConflicts: false), .blocked)
    }
}

// MARK: - Overall status derivation (shared by both pollers)

final class PipelineOverallStatusDeriveTests: XCTestCase {

    func test_mixed() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 2, inProgress: 0, queued: 0,
                                                    skipped: 0, failed: 1, totalJobs: 3), .mixed)
    }
    func test_failure() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 0, inProgress: 0, queued: 0,
                                                    skipped: 0, failed: 2, totalJobs: 2), .failure)
    }
    func test_running() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 1, inProgress: 1, queued: 0,
                                                    skipped: 0, failed: 0, totalJobs: 2), .running)
    }
    func test_queued() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 0, inProgress: 0, queued: 3,
                                                    skipped: 0, failed: 0, totalJobs: 3), .queued)
    }
    func test_emptyIsUnknown() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 0, inProgress: 0, queued: 0,
                                                    skipped: 0, failed: 0, totalJobs: 0), .unknown)
    }
    func test_allSuccess() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 4, inProgress: 0, queued: 0,
                                                    skipped: 0, failed: 0, totalJobs: 4), .success)
    }
    func test_skippedOnly() {
        XCTAssertEqual(PipelineOverallStatus.derive(succeeded: 0, inProgress: 0, queued: 0,
                                                    skipped: 2, failed: 0, totalJobs: 2), .skipped)
    }
}

// MARK: - Config store provider routing (UserDefaults-backed)

final class ConfigStoreProviderRoutingTests: XCTestCase {

    override func tearDown() {
        GitLabConfigStore.shared.resetForTesting()
        UserDefaults.standard.removeObject(forKey: "github_pipelines")
        super.tearDown()
    }

    func test_githubStore_ignoresGitLabPipelineURLs() {
        GitHubConfigStore.shared.pipelineURLs = [
            "https://github.com/foo/bar/actions/runs/1",
            "https://gitlab.com/g/p/-/pipelines/2",
        ]
        let parsed = GitHubConfigStore.shared.parsedPipelines
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.provider, .github)
    }

    func test_gitlabStore_ignoresGitHubPipelineURLs() {
        GitLabConfigStore.shared.pipelineURLs = [
            "https://github.com/foo/bar/actions/runs/1",
            "https://gitlab.com/g/p/-/pipelines/2",
        ]
        let parsed = GitLabConfigStore.shared.parsedPipelines
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.provider, .gitlab)
        XCTAssertEqual(parsed.first?.target, .pipeline(id: 2))
    }

    func test_gitlabStore_removePipeline() {
        GitLabConfigStore.shared.pipelineURLs = [
            "https://gitlab.com/g/p/-/pipelines/2",
            "https://gitlab.com/g/p/-/pipelines/3",
        ]
        let spec = PipelineSpec.parse("https://gitlab.com/g/p/-/pipelines/2")!
        GitLabConfigStore.shared.removePipeline(spec)
        XCTAssertEqual(GitLabConfigStore.shared.pipelineURLs,
                       ["https://gitlab.com/g/p/-/pipelines/3"])
    }
}
