import XCTest
@testable import OnyxCore
@testable import OnyxSSH
@testable import OnyxPad
import OnyxTestSupport

/// An agent on a host reaching an iPad: the bridge's port forwarded back
/// over the built-in client to the iPad's MCP server, against a real sshd.
final class PadAgentsSSHTests: XCTestCase {

    private var sshd: LocalSSHD!
    private var transport: NIOTransport!
    private var host: PadHost!
    private let port = Int.random(in: 41000..<48000)

    override func setUpWithError() throws {
        do { sshd = try LocalSSHD.start() } catch let why as LocalSSHD.Unavailable { throw XCTSkip(why.description) }
        let known = KnownHostsStore(url: nil)
        known.pin(host: sshd.hostName, port: sshd.port, key: sshd.hostPublicKey)
        let key = SSHIdentity(privateKey: try OpenSSHKeyFile.parse(String(contentsOf: sshd.clientKey, encoding: .utf8)),
                              source: "test key")
        transport = NIOTransport(knownHosts: known, connectTimeout: 5, identities: { _ in ([key], []) })
        let id = UUID()
        host = PadHost(config: HostConfig(id: id, label: "local-sshd", ssh: SSHConfig(host: "alias-only-a-mac-knows")),
                       route: HomeHostPointer(hostID: id, label: "local-sshd", address: sshd.hostName,
                                              port: sshd.port, user: sshd.user, hostKey: sshd.hostPublicKey))
    }

    override func tearDown() {
        transport?.disconnectAll()
        sshd?.stop()
        super.tearDown()
    }

    private func wait(for reach: @escaping (PadAgents.Reach?) -> Bool, on agents: PadAgents) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if reach(agents.reach[host.id]) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    func testAnAgentOnTheHostReachesTheIPad() throws {
        let agents = PadAgents(transport: transport, remotePort: port)
        agents.start()
        agents.reachAgents(on: host)
        XCTAssertTrue(wait(for: { $0 == .reaching }, on: agents), "\(String(describing: agents.reach[host.id]))")

        let connection = try XCTUnwrap(host.connection)
        // A script, not an exec line: it arrives on stdin, so its quotes
        // are its own.
        let out = transport.runScript(
            #"(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize"}'; sleep 1) | nc -w 2 127.0.0.1 "# + "\(port)",
            on: connection, delivery: .pipe, timeout: 15, label: "t")
        XCTAssertTrue(out.cleaned?.contains("\"serverInfo\"") == true, "\(out.failureDetail)\n\(sshd.log)")

        // Held here: another Onyx with its own connection — a Mac, say, or
        // a second iPad — finds the port taken, and says so.
        let known = KnownHostsStore(url: nil)
        known.pin(host: sshd.hostName, port: sshd.port, key: sshd.hostPublicKey)
        let key = SSHIdentity(privateKey: try OpenSSHKeyFile.parse(String(contentsOf: sshd.clientKey, encoding: .utf8)),
                              source: "test key")
        let elsewhere = NIOTransport(knownHosts: known, connectTimeout: 5, identities: { _ in ([key], []) })
        defer { elsewhere.disconnectAll() }
        let second = PadAgents(transport: elsewhere, remotePort: port)
        second.start()
        second.reachAgents(on: host)
        XCTAssertTrue(wait(for: { if case .elsewhere = $0 { return true }; return false }, on: second),
                      "\(String(describing: second.reach[host.id]))")
    }
}
