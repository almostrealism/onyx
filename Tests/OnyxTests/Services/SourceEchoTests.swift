import XCTest
@testable import OnyxLib

/// `cleanedOutput` strips the remote TTY's echo of our own script. Its
/// boundary rule — "keep everything after the last line containing
/// `$((1+1))`" — assumes the echo arrives as one BLOCK ahead of all
/// output. An interactive shell executes line by line, so its echo
/// interleaves with the output and that line lands at the very END.
/// Cutting there discarded everything: 2KB of good output in, empty
/// string out, and the git panel concluded "not a repo".
final class SourceEchoTests: XCTestCase {

    /// Captured verbatim from a real interactive zsh on a PTY, running the
    /// actual status script (escape codes and wrap artifacts removed).
    /// Note the ordering that broke it: real output first, the echo of the
    /// marker line AFTER it.
    private let interleaved = """
    worker@Mac-Studio onyx % sstty -echo 2>/dev/null

    worker@Mac-Studio onyx % PPATH="${PATH:-}:/usr/local/bin:/usr/bin:/bin"

    cd "/Users/worker/Projects/onyx" 2>/dev/null && git rev-parse --is-inside-work-t
    ree >/dev/null 2>&1 && { echo "---GIT_BRANCH---"; git branch --show-current 2>/d
    ev/null; echo "---GIT_HEAD---"; git rev-parse --short HEAD 2>/dev/null; echo "--
    -GIT_STATUS---"; git status --porcelain 2>/dev/null; echo "---GIT_PREFIX---"; gi
    t rev-parse --show-prefix 2>/dev/null; echo "---GIT_PREFIX_END---"; }

    ---GIT_BRANCH---
    master
    ---GIT_HEAD---
    c0e3341
    ---GIT_STATUS---
    ?? .git-panel-probe.tmp
     M Sources/OnyxLib/Managers/GitManager.swift
    ---GIT_DIFF_STAT---
    ---GIT_DIFF_CACHED_STAT---
    ---GIT_PREFIX---

    ---GIT_PREFIX_END---
    echo "---ONYX-OK-$((1+1))---"

    ---ONYX-OK-2---
    """

    func testInterleavedEchoDoesNotEraseTheOutput() {
        let cleaned = RemoteScript.cleanedOutput(interleaved)
        XCTAssertFalse(cleaned.isEmpty, "the whole response was thrown away")
        XCTAssertTrue(cleaned.contains("---GIT_BRANCH---"))
        XCTAssertTrue(cleaned.contains("master"))
        XCTAssertTrue(cleaned.contains("?? .git-panel-probe.tmp"))
    }

    /// End to end on that same capture: the panel must light up.
    func testGitPanelParsesAnInterleavedEchoResponse() {
        let manager = GitManager(appState: AppState())
        manager.parseOutput(RemoteScript.cleanedOutput(interleaved),
                            currentPath: "/Users/worker/Projects/onyx")
        XCTAssertTrue(manager.isGitRepo, "this is a repo and the output says so")
        XCTAssertEqual(manager.repoStatus?.branch, "master")
        XCTAssertEqual(manager.repoStatus?.changedFiles.count, 2)
        XCTAssertTrue(manager.repoStatus?.changedFiles.contains { $0.path == ".git-panel-probe.tmp" } ?? false)
    }

    /// The original case must still work: when the echo really is a
    /// leading block, everything before the boundary is noise and must go
    /// — otherwise the echoed markers are parsed as data.
    func testLeadingBlockEchoIsStillStripped() {
        let blockEcho = """
        stty -echo 2>/dev/null
        echo "---GIT_BRANCH---"; git branch --show-current
        echo "---ONYX-OK-$((1+1))---"
        ---GIT_BRANCH---
        main
        """
        let cleaned = RemoteScript.cleanedOutput(blockEcho)
        XCTAssertFalse(cleaned.contains("git branch --show-current"),
                       "the echoed source must be dropped when it IS a prefix")
        XCTAssertTrue(cleaned.contains("main"))
    }

    func testNoEchoAtAllIsUntouched() {
        let plain = "---GIT_BRANCH---\nmain\n---GIT_HEAD---\nabc1234\n"
        XCTAssertEqual(RemoteScript.cleanedOutput(plain), plain)
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(RemoteScript.cleanedOutput(""), "")
        XCTAssertEqual(RemoteScript.cleanedOutput("   \n  "), "   \n  ")
    }
}
