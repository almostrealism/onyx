import XCTest
@testable import OnyxLib

/// Tests for GitManager's extractSection + parseOutput on polluted captured
/// output. Mirrors the same scenarios as MonitorParserPollutionTests so any
/// future SSH-driven manager has a template to copy.
final class GitManagerParseTests: XCTestCase {

    private func makeManager() -> GitManager {
        GitManager(appState: AppState())
    }

    /// Realistic runtime portion of the git compound script (the part the
    /// parser is supposed to keep after `cleanedOutput` strips source echo).
    private static let realRuntime = """
    true
    ---GIT_BRANCH---
    main
    ---GIT_HEAD---
    abc1234
    ---GIT_STATUS---
     M src/main.swift
    ?? src/new.swift
    ---GIT_DIFF_STAT---
     src/main.swift | 5 +-
     1 file changed, 4 insertions(+), 1 deletion(-)
    ---GIT_DIFF_CACHED_STAT---
    ---GIT_PREFIX---
    ---GIT_PREFIX_END---
    """

    // MARK: - extractSection

    func test_extractSection_findsLastOccurrenceOfStartMarker() {
        // Source echo of `echo "---GIT_BRANCH---"` introduces a phantom
        // marker before the runtime one fires. We want the runtime
        // section (after the LAST occurrence), not the source-echo region.
        let raw = """
        echo "---GIT_BRANCH---" && git branch
        garbage source echo lines
        echo "---GIT_HEAD---" && git rev-parse
        ---GIT_BRANCH---
        main
        ---GIT_HEAD---
        abc1234
        """
        let gm = makeManager()
        let branch = gm.extractSection(raw,
                                       start: "---GIT_BRANCH---",
                                       end: "---GIT_HEAD---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "main",
                       "must pick the runtime section, not the source-echo region; got: \(branch.debugDescription)")
    }

    func test_extractSection_endIsFirstAfterStart() {
        // Once we've locked onto the LAST start marker, the end marker we
        // pick must be the FIRST one that appears after it — even if the
        // source echoed `end` literally further down.
        let raw = """
        ---GIT_STATUS---
        M  src/file.swift
        ---GIT_DIFF_STAT---
         file | 1 +
        """
        let gm = makeManager()
        let status = gm.extractSection(raw,
                                       start: "---GIT_STATUS---",
                                       end: "---GIT_DIFF_STAT---")
        XCTAssertTrue(status.contains("M  src/file.swift"))
        XCTAssertFalse(status.contains("file | 1 +"),
                       "end marker should cut before diff stats; got: \(status)")
    }

    func test_extractSection_returnsEmptyWhenStartAbsent() {
        let gm = makeManager()
        let s = gm.extractSection("no markers here at all",
                                  start: "---MISSING---",
                                  end: nil)
        XCTAssertEqual(s, "")
    }

    func test_extractSection_endNilGoesToEOF() {
        // The toplevel section uses end:nil because it's the trailing one.
        // cleanedOutput is expected to have already cut the trailing marker.
        let raw = """
        ---GIT_TOPLEVEL---
        /repo
        """
        let gm = makeManager()
        let tail = gm.extractSection(raw, start: "---GIT_TOPLEVEL---", end: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(tail, "/repo")
    }

    // MARK: - parseOutput end-to-end

    func test_parseOutput_pollutedByFullSourceEcho_yieldsCleanStatus() {
        // The most common bug shape — TTY echoes our git compound script
        // back; runtime output follows. Before the fix, parseOutput would
        // lock onto the source-echo `---GIT_BRANCH---` marker and the
        // resulting "branch" would be everything between source's BRANCH
        // marker and source's HEAD marker (just more shell source).
        let script = """
        git rev-parse --is-inside-work-tree 2>/dev/null && \\
        echo "---GIT_BRANCH---" && git branch --show-current 2>/dev/null && \\
        echo "---GIT_HEAD---" && git rev-parse --short HEAD 2>/dev/null && \\
        echo "---GIT_STATUS---" && git status --porcelain 2>/dev/null && \\
        echo "---GIT_DIFF_STAT---" && git diff --stat 2>/dev/null && \\
        echo "---GIT_DIFF_CACHED_STAT---" && git diff --cached --stat 2>/dev/null && \\
        echo "---GIT_PREFIX---" && git rev-parse --show-prefix 2>/dev/null && \\
        echo "---GIT_PREFIX_END---"
        """
        let raw = PollutedOutputFixture.fullEchoThenRuntime(
            script: script, runtime: Self.realRuntime)
        let cleaned = RemoteScript.cleanedOutput(raw)
        let gm = makeManager()
        gm.parseOutput(cleaned, currentPath: "/Users/me/code/repo")

        XCTAssertTrue(gm.isGitRepo, "polluted-but-real output must still be detected as a git repo")
        XCTAssertEqual(gm.repoStatus?.branch, "main",
                       "branch must be the runtime one, not source-echo gibberish")
        XCTAssertEqual(gm.repoStatus?.changedFiles.count, 2,
                       "should pick up the runtime status section (1 modified + 1 untracked)")
        XCTAssertEqual(gm.repoStatus?.diffStats?.insertions, 4)
        XCTAssertEqual(gm.repoStatus?.diffStats?.deletions, 1)
    }

    func test_parseOutput_rejectsSubdirectory_nonEmptyPrefix() {
        // In a subdirectory of a repo, `git rev-parse --show-prefix` is a
        // non-empty path ending in "/". GitManager must NOT show the landing
        // there (it's only for the repo root).
        let runtime = """
        true
        ---GIT_BRANCH---
        main
        ---GIT_HEAD---
        abc1234
        ---GIT_STATUS---
        ---GIT_DIFF_STAT---
        ---GIT_DIFF_CACHED_STAT---
        ---GIT_PREFIX---
        src/feature/
        ---GIT_PREFIX_END---
        """
        let cleaned = RemoteScript.cleanedOutput(
            PollutedOutputFixture.fullEchoThenRuntime(script: "git ...", runtime: runtime))
        let gm = makeManager()
        gm.parseOutput(cleaned, currentPath: "/Users/me/code/repo/src/feature")

        XCTAssertFalse(gm.isGitRepo,
                       "non-empty --show-prefix means a subdirectory — not the repo root")
        XCTAssertNil(gm.repoStatus)
    }

    func test_parseOutput_repoRoot_emptyPrefix_regardlessOfSymlinkSpelling() {
        // THE regression: the old code compared --show-toplevel (which git
        // canonicalises, e.g. /private/tmp/...) to the navigated path (e.g.
        // /tmp/...) and hid the panel when they differed by a symlink. The
        // empty --show-prefix means "this IS the root" no matter how the
        // path is spelled, so the landing must show.
        let runtime = """
        true
        ---GIT_BRANCH---
        main
        ---GIT_HEAD---
        abc1234
        ---GIT_STATUS---
         M file.swift
        ---GIT_DIFF_STAT---
        ---GIT_DIFF_CACHED_STAT---
        ---GIT_PREFIX---
        ---GIT_PREFIX_END---
        """
        let cleaned = RemoteScript.cleanedOutput(
            PollutedOutputFixture.fullEchoThenRuntime(script: "git ...", runtime: runtime))
        let gm = makeManager()
        // currentPath spelled with the symlink (/tmp), which would NOT have
        // matched git's canonical /private/tmp under the old equality check.
        gm.parseOutput(cleaned, currentPath: "/tmp/realrepo")

        XCTAssertTrue(gm.isGitRepo,
                      "empty --show-prefix is the repo root even when the path is a symlink alias")
        XCTAssertEqual(gm.repoStatus?.changedFiles.count, 1)
    }

    func test_parseOutput_emptyPrefixWithTrailingPromptNoise_stillRoot() {
        // On ssh -tt the prefix section's tail can carry prompt/exit echo.
        // An empty prefix (root) must survive that: only a line ending in
        // "/" counts as a subdirectory signal, so prompt noise is ignored.
        let runtime = """
        true
        ---GIT_BRANCH---
        main
        ---GIT_HEAD---
        abc1234
        ---GIT_STATUS---
        ---GIT_DIFF_STAT---
        ---GIT_DIFF_CACHED_STAT---
        ---GIT_PREFIX---
        ---GIT_PREFIX_END---
        user@host:~$ exit
        """
        let cleaned = RemoteScript.cleanedOutput(
            PollutedOutputFixture.fullEchoThenRuntime(script: "git ...", runtime: runtime))
        let gm = makeManager()
        gm.parseOutput(cleaned, currentPath: "/Users/me/code/repo")

        XCTAssertTrue(gm.isGitRepo, "trailing prompt noise must not be mistaken for a subdir prefix")
    }

    func test_parseOutput_handlesDetachedHEAD() {
        // No branch name → repoStatus.branch falls back to the short SHA
        // and `isDetachedHead == true`. Make sure last-section-wins
        // selection doesn't break this path.
        let runtime = """
        true
        ---GIT_BRANCH---

        ---GIT_HEAD---
        abc1234
        ---GIT_STATUS---
        ---GIT_DIFF_STAT---
        ---GIT_DIFF_CACHED_STAT---
        ---GIT_PREFIX---
        ---GIT_PREFIX_END---
        """
        let gm = makeManager()
        gm.parseOutput(RemoteScript.cleanedOutput(
            PollutedOutputFixture.fullEchoThenRuntime(script: "git ...",
                                                     runtime: runtime)),
                       currentPath: "/Users/me/code/repo")

        XCTAssertTrue(gm.isGitRepo)
        XCTAssertEqual(gm.repoStatus?.branch, "abc1234")
        XCTAssertEqual(gm.repoStatus?.isDetachedHead, true)
    }
}
