import XCTest
@testable import OnyxCore
@testable import OnyxLib
@testable import OnyxSSH

/// "Sync to iPhone and iPad": the pairing code, and the scripts that put
/// the Onyx key on the home host and take it off again.
final class DeviceSyncTests: XCTestCase {

    private let pointer = HomeHostPointer(hostID: UUID(), label: "studio", address: "studio.lan", port: 2222,
                                          user: "me", hostKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")

    // MARK: - The pairing code

    func testACodeSurvivesTextAndLink() throws {
        let code = PairingCode(home: pointer, key: "a2V5", tokens: ["github-token": "ghp_x"])
        XCTAssertEqual(PairingCode.parse(code.text), code)
        let url = try XCTUnwrap(code.url)
        XCTAssertEqual(url.scheme, "onyx-today")
        XCTAssertEqual(PairingCode.parse(url.absoluteString), code)
        // Wrapped across lines by a chat app or a terminal.
        let wrapped = code.text.enumerated().map { $0.offset % 20 == 19 ? "\($0.element)\n " : "\($0.element)" }.joined()
        XCTAssertEqual(PairingCode.parse(wrapped), code)
        XCTAssertNil(PairingCode.parse("hello"))
    }

    func testTokensAreDroppedRatherThanMakeAnUnscannableCode() {
        let huge = String(repeating: "t", count: 3000)
        let made = PairingCode.make(home: pointer, key: "a2V5", tokens: ["timing-token": huge])
        XCTAssertFalse(made.tokensIncluded)
        XCTAssertEqual(made.code.tokens, [:])
        let small = PairingCode.make(home: pointer, key: "a2V5", tokens: ["github-token": "ghp_x", "gitlab-token": ""])
        XCTAssertTrue(small.tokensIncluded)
        XCTAssertEqual(small.code.tokens, ["github-token": "ghp_x"], "empty tokens aren't carried")
    }

    func testInstallingACodeStoresTheKeyTheHostAndTheTokens() {
        let store = SecretStore(synced: InMemorySecretBackend(), local: nil,
                                defaults: UserDefaults(suiteName: "pair-\(UUID())")!)
        PairingCode(home: pointer, key: "a2V5", tokens: ["github-token": "ghp_x", "home-host": "evil"]).install(into: store)
        XCTAssertEqual(store.get(.sshPrivateKey), "a2V5")
        XCTAssertEqual(HomeHostPointer.load(from: store), pointer, "a token can't overwrite the pointer")
        XCTAssertEqual(store.get(.githubToken), "ghp_x")
    }

    // MARK: - The scripts, run for real against a scratch home

    private func run(_ script: String, home: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTheKeyIsAddedOnceAndRemovedAlone() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".ssh/authorized_keys")
        try "ssh-ed25519 AAAAothers someone@laptop\n".write(to: file, atomically: true, encoding: .utf8)

        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnyxKey onyx-sync"
        XCTAssertTrue(try run(DeviceSyncManager.installScript(line: line), home: home).contains("INSTALLED"))
        XCTAssertTrue(try run(DeviceSyncManager.installScript(line: line), home: home).contains("INSTALLED"))
        var text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: line).count - 1, 1, "added once, however often it's run")
        XCTAssertTrue(text.contains("someone@laptop"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        XCTAssertTrue(try run(DeviceSyncManager.removeScript(line: line), home: home).contains("REMOVED"))
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("onyx-sync"))
        XCTAssertTrue(text.contains("someone@laptop"), "nobody else's key is touched")
    }

    /// Both run through the TTY fallback: the ~1KB ceiling and the
    /// interactive shell's hazards apply (CLAUDE.md).
    func testTheScriptsAreSafeInATerminal() {
        let line = "ssh-ed25519 " + String(repeating: "A", count: 68) + " onyx-sync"
        for script in [DeviceSyncManager.installScript(line: line), DeviceSyncManager.removeScript(line: line)] {
            XCTAssertFalse(script.contains("!"), "history expansion: \(script)")
            XCTAssertLessThan(RemoteWire.terminalStdin(script).utf8.count, 1024)
        }
    }
}
