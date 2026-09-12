import XCTest
@testable import OnyxLib

/// The ~1KB ceiling, measured across every script that can reach a
/// terminal.
///
/// From CLAUDE.md, and from three separate outages: `ssh -tt` means the
/// far end is a terminal, a terminal's input buffer is ~1KB on macOS, and
/// everything past it is DISCARDED. The remote shell then waits forever
/// for the rest of a line and the caller sees nothing — no error, no exit
/// code worth reading, just a feature that silently reports nothing.
///
/// It has never announced itself. ~900 bytes of added GPU probing killed
/// stats on every Mac while Linux hosts carried on fine; the git status
/// script named the repo path eight times and died once a path passed ~30
/// characters; the file-search script named every selected extension and
/// died with the type filter fully enabled. Each was found by a user, not
/// by us.
///
/// So the ceiling is asserted here for the payload as actually sent —
/// wrapper included, since the wrapper is part of what the terminal has to
/// swallow — and with adversarial inputs, because every one of those
/// regressions was a script whose size scaled with something.
final class RemoteScriptBudgetTests: XCTestCase {

    /// macOS's terminal input buffer is ~1KB (Linux's is 4KB). The smaller
    /// one is the one that has to hold.
    private static let budget = 1024

    private func makeState(hostName: String = "build.example.com",
                           user: String = "mmurray") -> (AppState, HostConfig) {
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.label = "build"
        host.ssh.host = hostName
        host.ssh.user = user
        state.hosts = [host]
        return (state, host)
    }

    /// What the remote terminal actually has to swallow.
    private func payload(_ script: String, state: AppState, host: HostConfig) -> String {
        state.remoteScript(script, host: host).stdin ?? ""
    }

    private func assertFits(_ payload: String, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(payload.utf8.count, Self.budget,
                          "\(what) is \(payload.utf8.count)B — past the ~1KB a remote "
                          + "terminal will accept. It will be truncated and the feature will "
                          + "report nothing, with no error anywhere.",
                          file: file, line: line)
    }

    // MARK: - The monitor

    /// The one that broke every Mac. Stats are polled per host per tick, so
    /// this is also the script most likely to grow when someone adds "just
    /// one more reading".
    func testTheStatsScriptFits() {
        let (state, host) = makeState()
        let stdin = state.statsCommand(host: host).stdin ?? ""
        assertFits(stdin, "the stats script")
    }

    /// GPU probing lives in a SECOND command for exactly this reason —
    /// merging it back into stats is what broke it last time.
    func testEachAcceleratorProbeFitsOnItsOwn() {
        let (state, host) = makeState()
        for probe in [AppState.AcceleratorProbe.amdGPU, .npu] {
            let stdin = state.acceleratorCommand(probe, host: host).stdin ?? ""
            assertFits(stdin, "the \(probe) accelerator probe")
        }
    }

    /// Stats and accelerators travel separately, and must keep doing so:
    /// if the two ever fit in one payload the temptation to merge them
    /// returns, and the margin is not there.
    func testStatsAndAcceleratorsWouldNotFitTogether() {
        let (state, host) = makeState()
        let stats = (state.statsCommand(host: host).stdin ?? "").utf8.count
        let probe = [AppState.AcceleratorProbe.amdGPU, .npu]
            .map { (state.acceleratorCommand($0, host: host).stdin ?? "").utf8.count }
            .max() ?? 0
        XCTAssertGreaterThan(stats + probe, Self.budget,
                             "they fit together now — but the split is the design, and this "
                             + "test exists so merging them is a decision rather than an accident")
    }

    // MARK: - Shared state

    /// Both go through runScriptWithFallback, which retries over a TTY.
    func testTheSharedStateScriptsFit() {
        let (state, host) = makeState()
        assertFits(payload(SharedStateSync.makeDirectoryScript, state: state, host: host),
                   "the shared-state mkdir")
        assertFits(payload(SharedStateSync.moveIntoPlaceScript, state: state, host: host),
                   "the shared-state move")
    }

    // MARK: - Code intelligence

    @MainActor
    func testTheWorkspaceResolveScriptFitsForADeepPath() {
        let (state, host) = makeState()
        let deep = "/Users/someone/work/" + Array(repeating: "subdirectory", count: 8)
            .joined(separator: "/")
        assertFits(payload(LSPManager.workspaceResolveScript(startDir: deep),
                           state: state, host: host),
                   "the workspace resolve script for a \(deep.count)-character path")
    }

    func testTheJavaPreflightFits() {
        let (state, host) = makeState()
        assertFits(payload(JDTLSBootstrap.preflightScript(jdtlsPath: "$HOME/.onyx/jdtls"),
                           state: state, host: host),
                   "the Java preflight")
    }

    /// The other two ways an interactive remote shell eats a script, from
    /// CLAUDE.md: `!` is history expansion in zsh (which discards the whole
    /// line), and an unmatched glob in path position is FATAL under zsh's
    /// nomatch. AppStateTests locks the stats script this way; the LSP
    /// script is the other one that walks the filesystem.
    @MainActor
    func testTheWorkspaceScriptAvoidsTheInteractiveShellHazards() {
        let script = LSPManager.workspaceResolveScript(startDir: "/tmp/x")
        XCTAssertFalse(script.contains("!"),
                       "zsh expands ! as history and discards the line, comments included")
        XCTAssertFalse(script.contains("/*") || script.contains("*/") || script.contains("*."),
                       "an unmatched glob in path position aborts the script under zsh")
    }

    // MARK: - Git

    /// Covered in depth by GitScriptSizeTests; here so this file lists
    /// every TTY-bound script in one place rather than most of them.
    func testTheGitStatusScriptFits() {
        let (state, host) = makeState()
        assertFits(payload(GitManager.statusScript(for: "/Users/mmurray/work/monorepo/services/api"),
                           state: state, host: host),
                   "the git status script")
    }

    // MARK: - The wrapper itself

    /// Everything above has to fit INSIDE the wrapper, so the wrapper's own
    /// cost is a tax on every script. If it grows, every budget here
    /// shrinks — and a long username and hostname are part of it.
    func testTheWrapperIsASmallFractionOfTheBudget() {
        let (state, host) = makeState(
            hostName: "some-very-long-hostname.internal.example.com",
            user: "a-long-service-account-name")
        let overhead = payload("true", state: state, host: host).utf8.count
        XCTAssertLessThan(overhead, 200,
                          "the wrapper costs \(overhead)B before any script — that comes "
                          + "straight out of every payload measured in this file")
    }

    // MARK: - The exemption, and its guard rail

    /// The MCP install scripts are far past the ceiling on purpose: they
    /// travel by PIPE (`remoteScriptNoTTY`), which has no such limit.
    ///
    /// That makes them safe and fragile at once — safe as written, and one
    /// call-site change away from silent truncation, because
    /// `runScriptWithFallback` retries over a TTY. So the rule is asserted
    /// where it can't be enforced by a type: the installer must never use
    /// the fallback helper.
    func testTheInstallerNeverUsesTheTTYFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/OnyxLib/Managers/MCPInstaller.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("runScriptWithFallback"),
                       """
                       MCPInstaller's scripts exceed the ~1KB TTY ceiling by design and go \
                       over a pipe. runScriptWithFallback retries over a TTY, which would \
                       truncate them — and the symptom is an install that reports nothing.
                       """)
        XCTAssertTrue(source.contains("remoteScriptNoTTY"),
                      "the installer relies on the pipe path; if that changed, this file's "
                      + "reasoning about the install scripts no longer holds")
    }

    /// And the exempt scripts are measured anyway, so the size they are is
    /// a known number rather than a surprise — a pipe has no 1KB limit, but
    /// it is still worth knowing when one of these doubles.
    func testTheExemptInstallScriptsAreMeasuredNotIgnored() {
        let merge = MCPInstaller.settingsMergeScript(binaryPath: "/Users/Shared/.onyx/bin/OnyxMCP")
        let multi = MCPInstaller.multiUserScript(binaryPath: "/Users/Shared/.onyx/bin/OnyxMCP",
                                                 base: "/Users/Shared")
        let picker = MCPInstaller.claudePickerScript
        for (what, script) in [("settings merge", merge), ("multi-user", multi),
                               ("claude picker", picker)] {
            XCTAssertLessThan(script.utf8.count, 4096,
                              "\(what) is \(script.utf8.count)B; past 4KB even a Linux "
                              + "terminal's buffer is gone, and this would have to move "
                              + "to a staged file rather than a script")
        }
    }
}
