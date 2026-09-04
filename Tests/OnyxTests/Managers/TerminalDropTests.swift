import XCTest
@testable import OnyxLib

/// Dropping a file inserts text that is about to be executed, and — on a
/// remote session — writes a file to someone's home directory. Both of
/// those want the boring cases nailed down.
final class TerminalDropTests: XCTestCase {

    // MARK: - What gets typed

    func testPathsAreQuotedSoTheyRunAsTyped() {
        // The inserted text is meant to be runnable, not merely readable.
        XCTAssertEqual(TerminalDrop.quoted("/tmp/a file.txt"), "'/tmp/a file.txt'")
        XCTAssertEqual(TerminalDrop.quoted("/tmp/plain.txt"), "'/tmp/plain.txt'")
    }

    func testAQuoteInThePathCannotEndTheQuoting() {
        // Otherwise a filename is a command injection into the user's own
        // prompt.
        let out = TerminalDrop.quoted("/tmp/it's; rm -rf ~")
        XCTAssertTrue(out.hasPrefix("'") && out.hasSuffix("'"))
        XCTAssertFalse(out.contains("'; rm"), "the inner quote must be escaped")
    }

    func testMultipleFilesAreSeparatedAndLeaveRoomForTheNextArgument() {
        let text = TerminalDrop.insertionText(for: ["/a", "/b"])
        XCTAssertEqual(text, "'/a' '/b' ")
        XCTAssertTrue(text.hasSuffix(" "), "Terminal.app leaves a trailing space; so do we")
    }

    func testNothingDroppedTypesNothing() {
        XCTAssertEqual(TerminalDrop.insertionText(for: []), "")
    }

    // MARK: - Where it lands on the far machine

    /// The upload destination is built from the dropped file's name, so a
    /// hostile name must not be able to choose a path.
    func testAFilenameCannotEscapeItsDirectory() {
        let name = TerminalDrop.safeRemoteName(for: URL(fileURLWithPath: "/tmp/../../etc/passwd"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
    }

    func testALeadingDotDoesNotProduceAHiddenOrRelativeName() {
        XCTAssertEqual(TerminalDrop.safeRemoteName(for: URL(fileURLWithPath: "/tmp/.bashrc")),
                       "bashrc")
    }

    func testShellMetacharactersInNamesAreNeutralised() {
        let name = TerminalDrop.safeRemoteName(
            for: URL(fileURLWithPath: "/tmp/a;rm -rf ~ $(whoami).txt"))
        XCTAssertFalse(name.contains(";"))
        XCTAssertFalse(name.contains("$"))
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.hasSuffix(".txt"), "the extension is worth keeping")
    }

    func testOrdinaryNamesSurviveIntact() {
        // The point of keeping the basename: an agent pointed at a file
        // usually cares what it's called.
        XCTAssertEqual(TerminalDrop.safeRemoteName(for: URL(fileURLWithPath: "/x/report-2026_final.md")),
                       "report-2026_final.md")
    }

    func testAnUnnameableFileStillGetsAName() {
        XCTAssertFalse(TerminalDrop.safeRemoteName(for: URL(fileURLWithPath: "/tmp/...")).isEmpty)
    }

    func testTheUploadDirectoryHasNoSpacesInIt() {
        // Same reason ~/.onyx exists for control sockets: a path with a
        // space in it breaks things far downstream of here.
        XCTAssertFalse(TerminalDrop.remoteRelativeDir.contains(" "))
        XCTAssertFalse(TerminalDrop.remoteDisplayDir.contains(" "))
        XCTAssertFalse(TerminalDrop.containerDir.contains(" "))
    }

    /// scp resolves a relative destination against the remote home
    /// directory, so the upload never needs `~` expanded by a remote
    /// shell — which is the part of remote execution that keeps breaking.
    func testTheDestinationIsRelativeAndTheDisplayedPathIsNot() {
        XCTAssertFalse(TerminalDrop.remoteRelativeDir.hasPrefix("~"))
        XCTAssertFalse(TerminalDrop.remoteRelativeDir.hasPrefix("/"))
        XCTAssertTrue(TerminalDrop.remoteDisplayDir.hasPrefix("~/"))
        XCTAssertTrue(TerminalDrop.remoteDisplayDir.hasSuffix(TerminalDrop.remoteRelativeDir))
    }
}

/// The scp invocation. It rides the connection pair like everything else,
/// and it has one spelling trap that fails silently.
final class SCPCommandTests: XCTestCase {

    private func host(port: Int = 22, identity: String = "") -> HostConfig {
        HostConfig(label: "build", ssh: SSHConfig(host: "build.example.com", user: "me",
                                                  port: port, identityFile: identity))
    }

    func testItRidesTheExistingConnection() {
        let (cmd, args) = AppState().scpCommand(localPath: "/tmp/a.txt",
                                                remotePath: ".onyx/dropped/a.txt",
                                                host: host())
        XCTAssertEqual(cmd, "/usr/bin/scp")
        XCTAssertTrue(args.contains("ControlMaster=no"),
                      "a dropped file must never open a third connection to a host")
        XCTAssertTrue(args.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertEqual(args.last, "me@build.example.com:.onyx/dropped/a.txt")
    }

    /// scp spells the port -P; ssh spells it -p, and scp's -p means
    /// "preserve times". Getting it wrong doesn't error — it copies to
    /// the wrong daemon.
    func testPortUsesCapitalP() {
        let (_, args) = AppState().scpCommand(localPath: "/tmp/a.txt",
                                              remotePath: "x/a.txt",
                                              host: host(port: 2222))
        guard let i = args.firstIndex(of: "-P") else {
            return XCTFail("port must be passed as -P for scp")
        }
        XCTAssertEqual(args[i + 1], "2222")
    }

    func testDefaultPortIsNotPassedAtAll() {
        let (_, args) = AppState().scpCommand(localPath: "/tmp/a.txt",
                                              remotePath: "x/a.txt", host: host())
        XCTAssertFalse(args.contains("-P"))
    }

    func testIdentityFileIsForwardedWhenSet() {
        let (_, args) = AppState().scpCommand(localPath: "/tmp/a.txt", remotePath: "x/a.txt",
                                              host: host(identity: "/keys/id_ed25519"))
        guard let i = args.firstIndex(of: "-i") else { return XCTFail("identity not passed") }
        XCTAssertEqual(args[i + 1], "/keys/id_ed25519")
    }
}
