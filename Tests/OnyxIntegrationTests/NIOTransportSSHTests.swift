import XCTest
@testable import OnyxCore
@testable import OnyxLib
@testable import OnyxSSH
import OnyxTestSupport

/// The in-process transport against a real sshd — the same server and the
/// same calls as ProcessTransportSSHTests, so the two transports are held
/// to one standard: a manager must not be able to tell which answered.
final class NIOTransportSSHTests: XCTestCase {

    private var sshd: LocalSSHD!
    private var host: HostConfig!
    private var knownHosts: KnownHostsStore!
    private var transport: NIOTransport!
    private var clientKey: SSHIdentity!

    override func setUpWithError() throws {
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable {
            throw XCTSkip(why.description)
        }
        host = HostConfig(label: "local-sshd",
                          ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port))
        knownHosts = KnownHostsStore(url: nil)
        knownHosts.pin(host: sshd.hostName, port: sshd.port, key: sshd.hostPublicKey)
        clientKey = SSHIdentity(privateKey: try OpenSSHKeyFile.parse(
            String(contentsOf: sshd.clientKey, encoding: .utf8)), source: "test key")
        let key = clientKey!
        transport = NIOTransport(knownHosts: knownHosts, connectTimeout: 5,
                                 identities: { _ in ([key], []) })
    }

    override func tearDown() {
        transport?.disconnectAll()
        sshd?.stop()
        super.tearDown()
    }

    func testAScriptRunsOverAPipe() {
        let run = transport.runScript("echo remote-$((6*7))", on: host, delivery: .pipe, label: "t")
        XCTAssertEqual(run.cleaned?.trimmingCharacters(in: .whitespacesAndNewlines), "remote-42",
                       "\(run.failureDetail)\n\(sshd.log)")
    }

    func testAScriptRunsInATerminal() {
        let run = transport.runScript("echo tty-$((6*7))", on: host, delivery: .terminal, label: "t")
        XCTAssertTrue(run.cleaned?.contains("tty-42") == true, "\(run.failureDetail)\n\(run.preview)")
    }

    /// Bigger than a terminal's input queue: only pacing gets it through.
    func testALongScriptSurvivesATerminal() {
        let lines = (1...60).map { "echo line-\($0)-padding-padding-padding" }.joined(separator: "\n")
        let run = transport.runScript(lines, on: host, delivery: .terminal, timeout: 20, label: "t")
        XCTAssertTrue(run.cleaned?.contains("line-60-") == true, run.failureDetail)
    }

    func testACommandRunsInALoginShell() {
        let out = transport.runCommand("echo hi; echo oops >&2; exit 4", on: host, label: "t")
        XCTAssertEqual(out.exit, 4, out.stderr)
        XCTAssertTrue(out.stdout.contains("hi"))
        XCTAssertEqual(out.stderr, "oops")
    }

    func testFilesGoUpAndComeBack() throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("up.txt")
        // Several SFTP blocks, so the windowed reads and writes are exercised.
        let payload = String(repeating: "over the wire ", count: 20_000)
        try payload.write(to: src, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)

        let remote = ".onyx-nio-test-\(UUID().uuidString.prefix(8)).txt"
        defer { _ = transport.runCommand("rm -f ~/\(remote)", on: host, label: "cleanup") }
        let up = transport.upload(src.path, to: remote, on: host, recursive: false, timeout: 20, label: "t")
        XCTAssertEqual(up.exit, 0, up.stderr)
        let stat = transport.runCommand("stat -f %m ~/\(remote)", on: host, label: "t")
        XCTAssertEqual(stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1600000000",
                       "modification time preserved, like scp -p")

        let back = dir.appendingPathComponent("down.txt")
        let down = transport.download(remote, to: back.path, from: host, recursive: false, timeout: 20, label: "t")
        XCTAssertEqual(down.exit, 0, down.stderr)
        XCTAssertEqual(try String(contentsOf: back, encoding: .utf8), payload)
    }

    func testFoldersGoUpAndComeBack() throws {
        let dir = try tempDir()
        let tree = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: tree.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let remote = ".onyx-nio-tree-\(UUID().uuidString.prefix(8))"
        defer { _ = transport.runCommand("rm -rf ~/\(remote)", on: host, label: "cleanup") }
        XCTAssertEqual(transport.upload(tree.path, to: remote, on: host, recursive: true,
                                        timeout: 20, label: "t").exit, 0)
        XCTAssertEqual(transport.runCommand("cat ~/\(remote)/sub/b.txt", on: host, label: "t").stdout, "b")

        let back = dir.appendingPathComponent("back")
        let down = transport.download(remote, to: back.path, from: host, recursive: true, timeout: 20, label: "t")
        XCTAssertEqual(down.exit, 0, down.stderr)
        XCTAssertEqual(try String(contentsOf: back.appendingPathComponent("sub/b.txt"), encoding: .utf8), "b")
    }

    /// As scp: a file sent onto a folder lands inside it.
    func testAFileSentToAFolderLandsInIt() throws {
        let dir = try tempDir()
        let src = dir.appendingPathComponent("inside.txt")
        try "in".write(to: src, atomically: true, encoding: .utf8)
        let folder = ".onyx-nio-dir-\(UUID().uuidString.prefix(8))"
        defer { _ = transport.runCommand("rm -rf ~/\(folder)", on: host, label: "cleanup") }
        _ = transport.runCommand("mkdir ~/\(folder)", on: host, label: "t")
        XCTAssertEqual(transport.upload(src.path, to: folder, on: host, recursive: false,
                                        timeout: 20, label: "t").exit, 0)
        XCTAssertEqual(transport.runCommand("cat ~/\(folder)/inside.txt", on: host, label: "t").stdout, "in")
    }

    /// SharedStateSync's distinction between "not there" and "couldn't ask".
    func testAMissingFileIsNotAConnectionFailure() throws {
        let back = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let down = transport.download(".no-such-file-\(UUID().uuidString)", to: back.path, from: host,
                                      recursive: false, timeout: 20, label: "t")
        XCTAssertNotEqual(down.exit, 0)
        XCTAssertFalse(down.isTransportFailure)
        guard case .missing = SharedStateSync.classify(exit: down.exit, stderr: down.stderr) else {
            return XCTFail("classified as \(SharedStateSync.classify(exit: down.exit, stderr: down.stderr)): \(down.stderr)")
        }
    }

    func testAnUnreachableHostIsAConnectionFailure() {
        let nobody = HostConfig(label: "closed", ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: 1))
        let out = transport.runCommand("true", on: nobody, label: "t")
        XCTAssertTrue(out.isTransportFailure, out.stderr)
        XCTAssertTrue(out.stderr.contains("Connection refused"), out.stderr)
        guard case .connectionFailure = SharedStateSync.classify(exit: out.exit, stderr: out.stderr) else {
            return XCTFail("\(SharedStateSync.classify(exit: out.exit, stderr: out.stderr))")
        }
    }

    func testAJobStreamsFromTheHost() {
        let done = expectation(description: "exit")
        let lines = LineBuffer()
        var seen: [String] = []
        var status: Int32 = -2
        let lock = NSLock()
        transport.start(.script("for i in 1 2 3; do echo row$i; sleep 0.1; done", terminal: false), on: host,
                        timeout: 20, label: "t",
                        onOutput: { t in lock.lock(); seen += lines.append(t); lock.unlock() },
                        onExit: { code in status = code; done.fulfill() })
        wait(for: [done], timeout: 20)
        XCTAssertEqual(seen.filter { $0.hasPrefix("row") }, ["row1", "row2", "row3"])
        XCTAssertEqual(status, 0)
    }

    func testACancelledJobEnds() {
        let done = expectation(description: "exit")
        let job = transport.start(.command("sleep 30"), on: host, timeout: 60, label: "t",
                                  onOutput: { _ in }, onExit: { _ in done.fulfill() })
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { job.cancel() }
        wait(for: [done], timeout: 10)
    }

    /// More runs at once than one connection's session cap: they queue,
    /// they don't fail.
    func testManyRunsShareOneConnection() {
        let group = DispatchGroup()
        let lock = NSLock()
        var outputs: [String] = []
        for i in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                let out = self.transport.runCommand("sleep 0.3; echo n\(i)", on: self.host, timeout: 20, label: "t")
                lock.lock(); outputs.append(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)); lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(Set(outputs), Set((0..<12).map { "n\($0)" }))
    }

    func testADroppedConnectionIsReplaced() throws {
        XCTAssertEqual(transport.runCommand("true", on: host, label: "t").exit, 0)
        try transport.connection(for: host).close()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(transport.runCommand("echo again", on: host, label: "t").stdout, "again\n")
    }

    // MARK: - Trust

    func testAChangedHostKeyIsRefused() {
        let liar = KnownHostsStore(url: nil)
        liar.pin(host: sshd.hostName, port: sshd.port,
                 key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        let key = clientKey!
        let t = NIOTransport(knownHosts: liar, connectTimeout: 5, identities: { _ in ([key], []) })
        let out = t.runCommand("true", on: host, label: "t")
        XCTAssertTrue(out.isTransportFailure)
        XCTAssertTrue(out.stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"), out.stderr)
    }

    func testANewHostIsRememberedOnFirstSight() {
        let fresh = KnownHostsStore(url: nil)
        let key = clientKey!
        let t = NIOTransport(knownHosts: fresh, connectTimeout: 5, identities: { _ in ([key], []) })
        XCTAssertEqual(t.runCommand("true", on: host, label: "t").exit, 0)
        XCTAssertEqual(fresh.key(host: sshd.hostName, port: sshd.port), sshd.hostPublicKey)
        t.disconnectAll()
    }

    func testAnUnauthorizedKeyIsRefusedLikeOpenSSH() {
        let stranger = OnyxKey.loadOrCreate(in: SecretStore(synced: InMemorySecretBackend(), local: nil, defaults: UserDefaults(suiteName: "nio-\(UUID())")!))
        let t = NIOTransport(knownHosts: knownHosts, connectTimeout: 5, identities: { _ in ([stranger], []) })
        let out = t.runCommand("true", on: host, label: "t")
        XCTAssertTrue(out.isTransportFailure)
        XCTAssertTrue(out.stderr.contains("Permission denied (publickey)"), out.stderr)
        XCTAssertTrue(out.stderr.contains("the Onyx key"), "names what it tried: \(out.stderr)")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

/// The Mac's configuration of the built-in client — `ssh -G` for where and
/// as whom — against the same real server.
final class BuiltInSSHResolverTests: XCTestCase {

    func testTheResolverFindsTheServer() throws {
        let sshd: LocalSSHD
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable { throw XCTSkip(why.description) }
        defer { sshd.stop() }
        let host = HostConfig(label: "local-sshd",
                              ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port,
                                             identityFile: sshd.clientKey.path))
        let knownHosts = KnownHostsStore(url: nil)
        knownHosts.pin(host: sshd.hostName, port: sshd.port, key: sshd.hostPublicKey)
        let t = NIOTransport(knownHosts: knownHosts, connectTimeout: 5,
                             resolver: { try OpenSSHConfigResolver.shared.resolve($0) },
                             identities: { h in
                                 OpenSSHKeyFile.userKeys(at: (try? OpenSSHConfigResolver.shared.resolve(h))?.identityFiles ?? [])
                             })
        defer { t.disconnectAll() }
        let out = t.runCommand("echo resolved", on: host, label: "t")
        XCTAssertEqual(out.stdout, "resolved\n", out.stderr)
    }
}

/// The proof step of "Sync to iPhone and iPad": sign in the way the phone
/// will, and learn the host's address and key on the way.
final class DeviceSyncProofTests: XCTestCase {

    func testTheProofSignsInAndRecordsTheHost() throws {
        let sshd: LocalSSHD
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable { throw XCTSkip(why.description) }
        defer { sshd.stop() }
        let host = HostConfig(label: "home", ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port))
        let key = SSHIdentity(privateKey: try OpenSSHKeyFile.parse(String(contentsOf: sshd.clientKey, encoding: .utf8)),
                              source: "test key")
        switch DeviceSyncManager.prove(identity: key, home: host) {
        case .failure(let why):
            XCTFail(why.description)
        case .success(let pointer):
            // As ssh -G resolved it: OpenSSH writes 127.1 out in full.
            XCTAssertTrue(["127.1", "127.0.0.1"].contains(pointer.address), pointer.address)
            XCTAssertEqual(pointer.port, sshd.port)
            XCTAssertEqual(pointer.user, sshd.user)
            XCTAssertEqual(pointer.hostKey, sshd.hostPublicKey)
            XCTAssertEqual(pointer.hostID, host.id)
        }
    }

    func testAKeyTheHostRefusesIsCaughtOnTheMac() throws {
        let sshd: LocalSSHD
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable { throw XCTSkip(why.description) }
        defer { sshd.stop() }
        let host = HostConfig(label: "home", ssh: SSHConfig(host: sshd.hostName, user: sshd.user, port: sshd.port))
        let stranger = OnyxKey.loadOrCreate(in: SecretStore(synced: InMemorySecretBackend(), local: nil,
                                                            defaults: UserDefaults(suiteName: "p-\(UUID())")!))
        guard case .failure(let why) = DeviceSyncManager.prove(identity: stranger, home: host) else {
            return XCTFail("a refused key must not be published")
        }
        XCTAssertTrue(why.description.contains("Permission denied"), why.description)
    }
}
