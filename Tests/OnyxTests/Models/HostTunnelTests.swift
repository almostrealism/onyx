import XCTest
@testable import OnyxCore

/// Which host another is reached through: the chain, a loop, a removed
/// tunnel host, and what the picker may offer.
final class HostTunnelTests: XCTestCase {

    private func host(_ label: String, through: HostConfig? = nil) -> HostConfig {
        HostConfig(label: label, ssh: SSHConfig(host: "\(label).example"), tunnelHostID: through?.id)
    }

    func testADirectHostHasNoChain() {
        let a = host("a")
        XCTAssertEqual(try HostTunnel.chain(to: a, in: [a]).get(), [])
    }

    func testTheChainIsNearestFirst() throws {
        let gateway = host("gateway")
        let inner = host("inner", through: gateway)
        let deep = host("deep", through: inner)
        let path = try HostTunnel.chain(to: deep, in: [gateway, inner, deep]).get()
        XCTAssertEqual(path.map(\.label), ["gateway", "inner"])
    }

    func testARemovedTunnelHostIsNotADirectConnection() {
        let gone = host("gone")
        let inner = host("inner", through: gone)
        guard case .failure(.missing) = HostTunnel.chain(to: inner, in: [inner]) else {
            return XCTFail("a host whose tunnel is gone must not read as direct")
        }
    }

    func testALoopIsRefused() {
        var a = host("a")
        let b = host("b", through: a)
        a.tunnelHostID = b.id
        guard case .failure(.loop) = HostTunnel.chain(to: a, in: [a, b]) else {
            return XCTFail("a ↔ b must be a loop")
        }
    }

    func testThisMacIsNeverATunnel() {
        let inner = HostConfig(label: "inner", tunnelHostID: HostConfig.localhostID)
        guard case .failure(.missing) = HostTunnel.chain(to: inner, in: [.localhost, inner]) else {
            return XCTFail("localhost isn't a tunnel host")
        }
    }

    /// The picker offers every other remote host, but not one that is
    /// itself reached through this one.
    func testCandidatesLeaveOutLoops() {
        let a = host("a")
        let b = host("b", through: a)
        let c = host("c", through: b)
        let d = host("d")
        let hosts = [HostConfig.localhost, a, b, c, d]
        XCTAssertEqual(HostTunnel.candidates(for: a, in: hosts).map(\.label), ["d"])
        XCTAssertEqual(HostTunnel.candidates(for: c, in: hosts).map(\.label), ["a", "b", "d"])
        XCTAssertEqual(HostTunnel.dependents(of: a, in: hosts).map(\.label), ["b", "c"])
    }

    func testOldHostsDecodeAsDirect() throws {
        let json = #"{"id":"\#(UUID().uuidString)","label":"x","ssh":{"host":"x","user":"","port":22,"tmuxSession":"onyx","identityFile":""}}"#
        let decoded = try JSONDecoder().decode(HostConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.tunnelHostID)
    }

    func testTheTunnelSurvivesASave() throws {
        let a = host("a")
        let b = host("b", through: a)
        let back = try JSONDecoder().decode(HostConfig.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.tunnelHostID, a.id)
    }
}
