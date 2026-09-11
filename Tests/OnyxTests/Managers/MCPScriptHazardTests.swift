import XCTest
@testable import OnyxLib

/// The MCP install ships more shell to remote machines than anything
/// else in the app, and it arrived with none of the protections every
/// other remote script here has. CLAUDE.md is explicit that a new SSH
/// command builder gets a regression test — "vulnerable patterns should
/// fail at test time, not on a user's broken remote a year later" — and
/// these scripts were the exception.
///
/// Each rule below is one that has already cost this project a working
/// feature, in some cases more than once.
final class MCPScriptHazardTests: XCTestCase {

    private let binary = "/Users/Shared/.onyx/bin/OnyxMCP"

    /// Every piece of shell the MCP install can send to a host.
    private var scripts: [(String, String)] {
        [
            ("claude picker", MCPInstaller.claudePickerScript),
            ("hooks merge", MCPInstaller.settingsMergeScript(binaryPath: binary)),
            ("adopt script", MCPInstaller.multiUserScript(binaryPath: binary,
                                                          base: "/Users/Shared")),
        ]
    }

    /// `!` is history expansion in an interactive shell, and the remote
    /// shell IS interactive — that's how noexec hosts are defeated. zsh
    /// prints "event not found" and discards the whole LINE, so a single
    /// `!` silently deletes part of the script.
    func testNoHistoryExpansion() {
        for (name, script) in scripts {
            XCTAssertFalse(script.contains("!"),
                           "\(name) contains '!' — an interactive shell history-expands it "
                           + "and throws the line away")
        }
    }

    /// An unmatched glob is FATAL in zsh (`nomatch` is on by default)
    /// where sh and bash pass the pattern through. A path glob killed
    /// stats collection on every zsh host once already.
    func testNoPathGlobs() {
        for (name, script) in scripts {
            let offenders = script
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.contains("*") && $0.contains("/") }
            XCTAssertTrue(offenders.isEmpty,
                          "\(name) globs a path: \(offenders) — iterate a directory listing instead")
        }
    }

    /// The whole script arrives on the remote shell's stdin, so anything
    /// that reads stdin consumes the rest of it. Every external command
    /// that might is given an empty one.
    func testExternalCommandsCannotEatTheScript() {
        let install = MCPInstaller.claudePickerScript
        XCTAssertTrue(install.contains("</dev/null"),
                      "the picker runs `claude --version`; without </dev/null it reads the "
                      + "script as its input")
    }

    // MARK: - Quoting

    /// The install path is interpolated into shell. A space in it — and
    /// /Users/Shared is a directory people put things in — would split
    /// the command without quoting.
    func testThePathIsQuotedWhereverItIsInterpolated() {
        let path = "/Users/Some One/.onyx/bin/OnyxMCP"
        let script = MCPInstaller.multiUserScript(binaryPath: path, base: "/Users/Shared")
        XCTAssertFalse(script.contains("BIN=/Users/Some One"),
                       "an unquoted path with a space splits into two words")
    }

    func testQuotingSurvivesAnEmbeddedQuote() {
        let quoted = MCPInstaller.shellQuote("it's")
        XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        XCTAssertFalse(quoted.contains("it's"),
                       "the inner quote has to be escaped or it ends the quoting")
    }

    // MARK: - Behaviour the scripts must keep

    /// Hooks are merged into whatever is already there. A setup step that
    /// silently dropped someone's other hooks — or their other MCP
    /// servers — would be the worst thing in this file.
    func testHooksAreMergedRatherThanOverwritten() {
        let script = MCPInstaller.settingsMergeScript(binaryPath: binary)
        XCTAssertTrue(script.contains("settings.get(\"hooks\")"),
                      "existing settings must be read before being written")
        XCTAssertTrue(script.contains("OnyxMCP") && script.contains("not in str"),
                      "only OUR hook entries should be replaced")
    }

    /// Without python3 the script must NOT write a settings file over one
    /// that exists. A half-understood rewrite of someone's config is not
    /// worth the convenience.
    func testWithoutPython3ItDoesNotRewriteSettings() {
        let script = MCPInstaller.settingsMergeScript(binaryPath: binary)
        XCTAssertTrue(script.contains("hooks skipped"),
                      "the no-python3 branch should decline, not guess")
    }

    /// The adopt script is handed to another human to run. It has to fail
    /// loudly rather than half-registering something.
    func testTheAdoptScriptChecksBeforeItActs() {
        let script = MCPInstaller.multiUserScript(binaryPath: binary, base: "/Users/Shared")
        XCTAssertTrue(script.contains("[ -x \"$BIN\" ] ||"),
                      "it should check the shared binary is really there")
        XCTAssertTrue(script.contains("No working 'claude' found"),
                      "and that a usable claude exists")
        XCTAssertTrue(script.contains("mcp get onyx"),
                      "and confirm the registration rather than assuming it")
    }

    /// Only a shared install can be adopted; a home-directory one is not
    /// readable by other accounts, so no script is written for it.
    func testNoAdoptScriptForAHomeDirectoryInstall() {
        XCTAssertTrue(MCPInstaller.multiUserScript(binaryPath: "/home/me/.onyx/bin/OnyxMCP",
                                                   base: "/home/me").isEmpty)
    }
}
