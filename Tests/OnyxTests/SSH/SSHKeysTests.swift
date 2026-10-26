import XCTest
import Crypto
import NIOCore
import NIOSSH
@testable import OnyxCore
@testable import OnyxSSH

/// Keys the built-in client can sign in with — and the ones it can't, which
/// must be skipped with a reason rather than fail the connection.
final class SSHKeysTests: XCTestCase {

    private func keygen(_ type: String, passphrase: String = "") throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else {
            throw XCTSkip("no ssh-keygen")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("k")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", type, "-N", passphrase, "-f", file.path] + (type == "rsa" ? ["-b", "2048"] : [])
        try p.run()
        p.waitUntilExit()
        let pub = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
        return try String(contentsOf: file, encoding: .utf8) + "\u{0}" + pub
    }

    private func check(_ type: String) throws {
        let both = try keygen(type).split(separator: "\u{0}").map(String.init)
        let key = try OpenSSHKeyFile.parse(both[0])
        // The public half we derive is the one ssh-keygen wrote.
        XCTAssertEqual(String(openSSHPublicKey: key.publicKey),
                       both[1].split(separator: " ").prefix(2).joined(separator: " "))
    }

    func testEd25519Parses() throws { try check("ed25519") }
    func testECDSAParses() throws { try check("ecdsa") }

    func testRSAIsSkippedWithAReason() throws {
        let text = try keygen("rsa").split(separator: "\u{0}").map(String.init)[0]
        XCTAssertThrowsError(try OpenSSHKeyFile.parse(text)) { error in
            XCTAssertEqual(error as? OpenSSHKeyFile.ParseError, .unsupportedKeyType("ssh-rsa"))
        }
    }

    func testAPassphraseIsSkippedWithAReason() throws {
        let text = try keygen("ed25519", passphrase: "secret").split(separator: "\u{0}").map(String.init)[0]
        XCTAssertThrowsError(try OpenSSHKeyFile.parse(text)) { error in
            XCTAssertEqual(error as? OpenSSHKeyFile.ParseError, .encrypted)
        }
    }

    func testGarbageIsNotAKey() {
        XCTAssertThrowsError(try OpenSSHKeyFile.parse("hello")) { error in
            XCTAssertEqual(error as? OpenSSHKeyFile.ParseError, .notOpenSSHFormat)
        }
    }

    func testTheOnyxKeyIsMadeOnceAndKept() {
        let store = SecretStore(synced: InMemorySecretBackend(), local: nil,
                                defaults: UserDefaults(suiteName: "keys-\(UUID())")!)
        XCTAssertNil(OnyxKey.load(from: store))
        let made = OnyxKey.loadOrCreate(in: store)
        let again = OnyxKey.loadOrCreate(in: store)
        XCTAssertEqual(String(openSSHPublicKey: made.privateKey.publicKey),
                       String(openSSHPublicKey: again.privateKey.publicKey))
        XCTAssertTrue(made.authorizedKeysLine(comment: OnyxKey.comment).hasSuffix(" onyx-sync"))
        XCTAssertTrue(made.authorizedKeysLine(comment: OnyxKey.comment).hasPrefix("ssh-ed25519 "))
    }

    func testUnusableKeyFilesAreReportedNotFatal() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rsa = try keygen("rsa").split(separator: "\u{0}").map(String.init)[0]
        let ed = try keygen("ed25519").split(separator: "\u{0}").map(String.init)[0]
        try rsa.write(to: home.appendingPathComponent(".ssh/custom"), atomically: true, encoding: .utf8)
        try ed.write(to: home.appendingPathComponent(".ssh/id_ed25519"), atomically: true, encoding: .utf8)
        let host = HostConfig(label: "h", ssh: SSHConfig(host: "h", identityFile: home.appendingPathComponent(".ssh/custom").path))
        let found = OpenSSHKeyFile.userKeys(for: host, home: home)
        XCTAssertEqual(found.usable.map(\.source), ["~/.ssh/id_ed25519"])
        XCTAssertEqual(found.skipped.count, 1)
        XCTAssertTrue(found.skipped[0].contains("ssh-rsa"), found.skipped[0])
    }
}

final class KnownHostsTests: XCTestCase {

    private func key() -> NIOSSHPublicKey {
        NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
    }

    func testFirstSightIsRememberedThenTrusted() {
        let store = KnownHostsStore(url: nil)
        let k = key()
        XCTAssertEqual(store.verify(host: "h", port: 22, presented: k), .new)
        XCTAssertEqual(store.verify(host: "h", port: 22, presented: k), .trusted)
    }

    func testAChangedKeyIsRefused() {
        let store = KnownHostsStore(url: nil)
        let first = key()
        _ = store.verify(host: "h", port: 2222, presented: first)
        guard case .changed(let expected) = store.verify(host: "h", port: 2222, presented: key()) else {
            return XCTFail("a different key must not be trusted")
        }
        XCTAssertEqual(expected, String(openSSHPublicKey: first))
    }

    func testPortsAreDifferentHosts() {
        let store = KnownHostsStore(url: nil)
        _ = store.verify(host: "h", port: 22, presented: key())
        XCTAssertEqual(store.verify(host: "h", port: 2200, presented: key()), .new)
    }

    func testThePinnedKeyIsTheOnlyOneTrusted() {
        let store = KnownHostsStore(url: nil)
        let k = key()
        store.pin(host: "home", port: 22, key: String(openSSHPublicKey: k) + " comment")
        XCTAssertEqual(store.verify(host: "home", port: 22, presented: k), .trusted)
        if case .changed = store.verify(host: "home", port: 22, presented: key()) {} else {
            XCTFail("a pinned host's other keys are refused")
        }
    }

    func testItPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let k = key()
        _ = KnownHostsStore(url: url).verify(host: "h", port: 22, presented: k)
        XCTAssertEqual(KnownHostsStore(url: url).verify(host: "h", port: 22, presented: k), .trusted)
    }

    /// OpenSSH's file, plain and hashed: what it knows, we know; what it
    /// would refuse, we refuse.
    func testOpenSSHKnownHostsAreHonored() throws {
        let k = key()
        let line = String(openSSHPublicKey: k)
        let salt = Data((0..<20).map { UInt8($0) })
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("[hashed]:2222".utf8), using: SymmetricKey(data: salt))
        let hashed = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        # comment
        plain,alias \(line) user@box
        \(hashed) \(line)

        """.write(to: file, atomically: true, encoding: .utf8)
        let store = KnownHostsStore(url: nil, openSSHFiles: [file])
        XCTAssertEqual(store.verify(host: "alias", port: 22, presented: k), .trusted)
        XCTAssertEqual(store.verify(host: "hashed", port: 2222, presented: k), .trusted)
        if case .changed = store.verify(host: "plain", port: 22, presented: key()) {} else {
            XCTFail("a key OpenSSH would refuse is refused")
        }
        XCTAssertEqual(store.verify(host: "elsewhere", port: 22, presented: k), .new)
    }
}

/// How invocations go on the wire: the same text the process transport sends.
final class NIOTransportWireTests: XCTestCase {

    func testACommandIsAnExecOfTheLoginShell() {
        let (request, terminal, stdin) = NIOTransport.session(for: .command("ls"))
        XCTAssertEqual(request, .exec(RemoteWire.execCommand("ls")))
        XCTAssertNil(terminal)
        guard case .piped(let data) = stdin else { return XCTFail() }
        XCTAssertTrue(data.isEmpty, "EOF at once: a command must not wait on stdin")
    }

    func testAPipeScriptIsAShellWithoutATerminal() {
        let (request, terminal, stdin) = NIOTransport.session(for: .script("echo x", terminal: false))
        XCTAssertEqual(request, .shell)
        XCTAssertNil(terminal)
        guard case .piped(let data) = stdin else { return XCTFail() }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), RemoteWire.pipeStdin("echo x"))
    }

    func testATerminalScriptIsPaced() {
        let (_, terminal, stdin) = NIOTransport.session(for: .script("echo x", terminal: true))
        XCTAssertNotNil(terminal)
        guard case .paced(let data, let chunk, let pause) = stdin else { return XCTFail() }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), RemoteWire.terminalStdin("echo x"))
        XCTAssertEqual(chunk, RemoteWire.terminalChunk)
        XCTAssertEqual(pause, RemoteWire.terminalPause)
    }

    func testFailuresFollowSSHAndSCPConventions() {
        let missing = NIOTransport.output(for: SFTPError(code: SFTPError.noSuchFile, message: "", path: "x"))
        XCTAssertEqual(missing.exit, 1)
        XCTAssertEqual(missing.stderr, "scp: x: No such file or directory")
        let refused = NIOTransport.output(for: SSHConnectionError.unreachable(host: "h", port: 22, reason: "Connection refused"))
        XCTAssertTrue(refused.isTransportFailure)
        XCTAssertEqual(refused.stderr, "ssh: connect to host h port 22: Connection refused")
    }

    /// Only "no address at all" is this device. A loopback address is a
    /// server like any other — from an iOS simulator it's the Mac.
    func testOnlyAnEmptyAddressIsThisDevice() {
        XCTAssertTrue(NIOTransport.isThisDevice(.localhost))
        XCTAssertFalse(NIOTransport.isThisDevice(HostConfig(label: "l", ssh: SSHConfig(host: "127.0.0.1"))))
        XCTAssertFalse(NIOTransport.isThisDevice(HostConfig(label: "l", ssh: SSHConfig(host: "localhost"))))
    }

    func testATildeMeansTheHome() {
        XCTAssertEqual(SFTPClient.wirePath("~/.onyx/x"), ".onyx/x")
        XCTAssertEqual(SFTPClient.wirePath("~"), ".")
        XCTAssertEqual(SFTPClient.wirePath("/etc/hosts"), "/etc/hosts")
        XCTAssertEqual(SFTPClient.wirePath(".onyx/x"), ".onyx/x")
    }

    func testLinesAreNotDecodedInHalves() {
        let lines = Utf8Lines()
        var b = ByteBufferAllocator().buffer(capacity: 8)
        let euro = Array("€\n".utf8)
        b.writeBytes(euro.prefix(2))
        XCTAssertEqual(lines.append(b), "")
        var c = ByteBufferAllocator().buffer(capacity: 8)
        c.writeBytes(euro.dropFirst(2))
        XCTAssertEqual(lines.append(c), "€\n")
    }
}
