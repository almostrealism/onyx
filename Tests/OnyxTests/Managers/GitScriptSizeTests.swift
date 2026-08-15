import XCTest
@testable import OnyxLib

/// Git queries go over the same `-tt` path as everything else, so they're
/// bound by the same ~1KB-per-payload ceiling a remote terminal imposes.
/// This one broke quietly: the status script named the repo path EIGHT
/// times, so it crossed the ceiling once a path got past ~30 characters.
/// The session then hung, no output came back, and the browser concluded
/// the directory simply wasn't a repo — no error anywhere.
final class GitScriptSizeTests: XCTestCase {

    private func payload(for path: String) -> String {
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        host.ssh.user = "mmurray"
        state.hosts = [host]
        return state.remoteScript(GitManager.statusScript(for: path), host: host).stdin ?? ""
    }

    func testStatusPayloadFitsForRealisticProjectPaths() {
        for path in [
            "/Users/mmurray/p",
            "/Users/michael/AlmostRealism/sandboxB",
            "/Users/michael/AlmostRealism/sandboxB/five9-services/backend",
        ] {
            let size = payload(for: path).count
            XCTAssertLessThan(size, 1024,
                              "\(path) → \(size)B; a remote terminal will truncate this and "
                              + "the repo will silently look like a non-repo")
        }
    }

    /// Deep monorepo paths are exactly where this used to fail hardest.
    func testStatusPayloadFitsForAVeryLongPath() {
        let deep = "/Users/someone/work/" + Array(repeating: "subdirectory", count: 8).joined(separator: "/")
        XCTAssertGreaterThan(deep.count, 100, "test needs a genuinely long path")
        XCTAssertLessThan(payload(for: deep).count, 1024, "\(payload(for: deep).count)B")
    }

    /// The fix, stated as a property: name the path once, not per command.
    func testPathAppearsOnlyOnceHoweverManyGitCommandsRun() {
        let path = "/Users/michael/AlmostRealism/sandboxB"
        let script = GitManager.statusScript(for: path)
        let occurrences = script.components(separatedBy: path).count - 1
        XCTAssertEqual(occurrences, 1,
                       "repeating the path per git command is what blew the budget")
        // …and it still asks for everything the panel needs.
        for marker in ["---GIT_BRANCH---", "---GIT_HEAD---", "---GIT_STATUS---",
                       "---GIT_DIFF_STAT---", "---GIT_DIFF_CACHED_STAT---",
                       "---GIT_PREFIX---", "---GIT_PREFIX_END---"] {
            XCTAssertTrue(script.contains(marker), "\(marker) missing")
        }
    }

    /// One statement: a multi-line construct would be handed to the remote
    /// shell's line editor, which is far slower than the input arrives.
    func testStatusScriptIsASingleLine() {
        let script = GitManager.statusScript(for: "/tmp/repo")
        XCTAssertFalse(script.contains("\n"))
        XCTAssertFalse(script.contains("!"), "history expansion in an interactive shell")
    }

    /// Not a repo → no markers at all, which is what the parser keys on.
    func testNonRepoStillEmitsNothing() {
        let script = GitManager.statusScript(for: "/tmp/repo")
        XCTAssertTrue(script.hasPrefix("cd "), "must cd first")
        XCTAssertTrue(script.contains("rev-parse --is-inside-work-tree >/dev/null 2>&1 && {"),
                      "the whole block must hang off the repo check")
    }
}

/// File search is bound by the same payload ceiling. With every file type
/// selected the extension clause alone ran to ~700 bytes, putting the
/// script over — so search would have gone silent on Macs exactly as git
/// status did.
final class SearchScriptSizeTests: XCTestCase {

    private func payload(_ script: String) -> Int {
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        return (state.remoteScript(script, host: host).stdin ?? "").count
    }

    private var allExtensions: [String] {
        SearchFileType.extensions(forSelectedIDs: SearchFileType.presets.map { $0.id })
    }

    func testFitsWithEveryFileTypeSelected() {
        let deep = "'/Users/michael/AlmostRealism/sandboxB/five9-services/backend/src/main/java'"
        let command = FileBrowserManager.searchCommand(
            escapedBase: deep, query: "ServiceImpl",
            extensions: allExtensions, maxResults: 200)
        XCTAssertLessThan(payload(command.script), 1024,
                          "\(payload(command.script))B — search would silently return nothing")
        XCTAssertTrue(command.filterExtensionsLocally,
                      "the clause didn't fit, so the filter must move to the results")
    }

    /// A handful of types still filters remotely — that's cheaper and
    /// exact, and it easily fits.
    func testSmallSelectionStillFiltersRemotely() {
        let command = FileBrowserManager.searchCommand(
            escapedBase: "'/srv/app'", query: "Foo",
            extensions: ["swift", "java", "py"], maxResults: 200)
        XCTAssertFalse(command.filterExtensionsLocally)
        XCTAssertTrue(command.script.contains("*.swift"))
        XCTAssertLessThan(payload(command.script), 1024)
    }

    /// Falling back to local filtering must not shrink the result set:
    /// ask the remote for more, since most of what comes back is dropped.
    func testLocalFilterFallbackAsksForMoreResults() {
        let command = FileBrowserManager.searchCommand(
            escapedBase: "'/srv/app'", query: "Foo",
            extensions: allExtensions, maxResults: 200)
        XCTAssertTrue(command.script.contains("head -800"),
                      "should over-fetch when filtering locally; got: \(command.script)")
    }

    func testNoFilterIsUnchanged() {
        let command = FileBrowserManager.searchCommand(
            escapedBase: "'/srv/app'", query: "Foo", extensions: [], maxResults: 200)
        XCTAssertFalse(command.filterExtensionsLocally)
        XCTAssertTrue(command.script.contains("head -200"))
    }
}
