import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Editing a file on a host by hand: exact bytes in and out, and a save
/// that writes into the file rather than replacing it.
final class RemoteFileEditTests: XCTestCase {

    // MARK: What may be edited

    func testOnlyExactUTF8UnderTheLimitIsEditable() {
        XCTAssertNil(RemoteFileEdit.refusal(for: Data("hello\r\nworld\n".utf8)))
        XCTAssertNotNil(RemoteFileEdit.refusal(for: Data([0xff, 0xfe, 0x00])))
        XCTAssertNotNil(RemoteFileEdit.refusal(for: Data(count: RemoteFileEdit.maxEditableBytes + 1)))
    }

    func testCRLFSurvivesTheRoundTrip() {
        let data = Data("a\r\nb\r\n".utf8)
        XCTAssertEqual(RemoteFileEdit.decode(data).map { Data($0.utf8) }, data)
    }

    // MARK: Paths

    func testScpPathsNeverRelyOnTildeExpansion() {
        XCTAssertEqual(RemoteFileEdit.scpPath("~/src/app.py"), "src/app.py")
        XCTAssertEqual(RemoteFileEdit.scpPath("/etc/hosts"), "/etc/hosts")
    }

    func testTheTemporaryIsHiddenBesideTheFile() {
        XCTAssertEqual(RemoteFileEdit.temporaryPath(for: "/srv/app/main.py", token: "ab12"),
                       "/srv/app/.main.py.onyx-save-ab12")
        XCTAssertEqual(RemoteFileEdit.temporaryPath(for: "~/x.txt", token: "t"), "~/.x.txt.onyx-save-t")
    }

    func testTheCommitScriptIsSafeForAnInteractiveShell() {
        let script = RemoteFileEdit.commitScript(temporary: "/a/.b.onyx-save-1", target: "/a/it's *b*")
        XCTAssertFalse(script.contains("!"), "history expansion")
        XCTAssertLessThan(script.utf8.count, 1024)
        // Every * is inside single quotes.
        XCTAssertTrue(script.contains("'it'\\''s *b*'"))
    }

    // MARK: The script, run for real

    private func sh(_ script: String, home: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testCommitWritesIntoTheFileKeepingModeAndSymlinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("onyx-edit-\(UUID())/it's a dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir.deletingLastPathComponent()) }

        let real = dir.appendingPathComponent("real file.sh")
        try Data("old\n".utf8).write(to: real)
        try fm.setAttributes([.posixPermissions: 0o750], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("link.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let temporary = RemoteFileEdit.temporaryPath(for: link.path, token: "t1")
        try Data("new\r\n".utf8).write(to: URL(fileURLWithPath: temporary))

        let out = try sh(RemoteFileEdit.commitScript(temporary: temporary, target: link.path), home: "/")
        XCTAssertTrue(out.contains(RemoteFileEdit.savedMarker))
        XCTAssertEqual(try Data(contentsOf: real), Data("new\r\n".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), real.path, "still a link")
        XCTAssertEqual((try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int), 0o750)
        XCTAssertFalse(fm.fileExists(atPath: temporary), "temporary removed")
    }

    func testTildePathsExpandInTheShell() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("onyx-home-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        try Data("old".utf8).write(to: home.appendingPathComponent("f.txt"))
        try Data("new".utf8).write(to: home.appendingPathComponent(".f.txt.onyx-save-x"))

        let out = try sh(RemoteFileEdit.commitScript(temporary: "~/.f.txt.onyx-save-x", target: "~/f.txt"),
                         home: home.path)
        XCTAssertTrue(out.contains(RemoteFileEdit.savedMarker))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("f.txt")), "new")
    }

    func testAFailedCopyKeepsTheTemporary() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("onyx-edit-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("no-such-dir/f.txt").path
        let temporary = dir.appendingPathComponent(".f.txt.onyx-save-x").path
        try Data("new".utf8).write(to: URL(fileURLWithPath: temporary))

        let out = try sh(RemoteFileEdit.commitScript(temporary: temporary, target: target), home: "/")
        XCTAssertFalse(out.contains(RemoteFileEdit.savedMarker))
        XCTAssertTrue(fm.fileExists(atPath: temporary))
    }
}
