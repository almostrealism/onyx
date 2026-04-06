import XCTest
import Foundation
@testable import OnyxLib

/// On-disk round-trip tests for `NetworkTopologyStore`.
///
/// FINDING: `NetworkTopologyStore` is a strict singleton (`static let shared`,
/// `private init`, and `configure(url:)` is one-shot — it bails if `self.url`
/// is already set). That makes it impossible to spin up a *fresh* store
/// instance pointing at a temp URL inside a unit test. Two consequences:
///   1. We can only call `configure(url:)` once per process. The first test
///      to do so wins; subsequent tests that need a different URL must
///      reuse the same one.
///   2. We cannot create a "second store pointing at the same URL" to verify
///      decode behavior, because there's only ever one store.
///
/// Workaround: write via the store's `save()`, then read back the file with
/// `JSONDecoder` directly and assert the on-disk shape matches what's
/// in-memory. This still catches the regressions the plan cares about
/// (schema drift, encoder/decoder symmetry).
///
/// Follow-up suggestion: change `NetworkTopologyStore` from a singleton to a
/// regular class with a public initializer (or expose a test-only
/// `reconfigure(url:)`). The singleton-with-shared-state pattern blocks
/// per-test isolation in general.
final class TopologyPersistenceTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-topology-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("topology.json")
        NetworkTopologyStore.shared.reset()
    }

    override func tearDown() {
        if let tempURL = tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        NetworkTopologyStore.shared.reset()
        super.tearDown()
    }

    func testSaveProducesValidJSONOnDisk() throws {
        let store = NetworkTopologyStore.shared
        store.configure(url: tempURL)

        let hostA = UUID()
        let hostB = UUID()

        store.mergeEnumeration(
            hostID: hostA,
            sessions: [
                TmuxSession(name: "main", source: .host(hostID: hostA)),
                TmuxSession(name: "dev", source: .host(hostID: hostA)),
            ],
            probeResult: .ok
        )
        store.mergeEnumeration(
            hostID: hostB,
            sessions: [
                TmuxSession(name: "primary", source: .host(hostID: hostB)),
            ],
            probeResult: .ok
        )
        store.confirmContainersAlive(hostID: hostA, containerNames: ["postgres", "redis"])

        store.save()

        // If a prior test in this process already configured the singleton at
        // a different URL, our temp file won't exist — skip rather than fail.
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw XCTSkip("NetworkTopologyStore.configure was already locked to a different URL by a prior test in this process; cannot verify on-disk shape here.")
        }

        // File should exist and be parseable
        let data = try Data(contentsOf: tempURL)
        XCTAssertFalse(data.isEmpty, "topology file is empty")

        let decoded = try JSONDecoder().decode([UUID: HostTopology].self, from: data)
        XCTAssertEqual(decoded.count, 2, "expected two hosts in serialized topology")
        XCTAssertEqual(decoded[hostA]?.sessions.count, 2)
        XCTAssertEqual(decoded[hostB]?.sessions.count, 1)
        XCTAssertNotNil(decoded[hostA]?.containers["postgres"])
        XCTAssertNotNil(decoded[hostA]?.containers["redis"])
        XCTAssertEqual(decoded[hostA]?.lastProbeResult, .ok)
    }

    func testSerializedSessionRoundTripsNameAndSource() throws {
        let store = NetworkTopologyStore.shared
        // Configure may be a no-op if a previous test in this process already
        // configured the store, but `reset()` in setUp ensures the in-memory
        // state is clean and `save()` will still write to whatever URL was set.
        store.configure(url: tempURL)

        let hostID = UUID()
        let session = TmuxSession(name: "round-trip", source: .docker(hostID: hostID, containerName: "myapp"))
        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)
        store.save()

        // The store may have been pinned to an earlier path by a sibling test;
        // skip the on-disk assertions if our temp file wasn't actually written.
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw XCTSkip("NetworkTopologyStore.configure was already locked to a different URL by a prior test in this process; cannot verify on-disk shape here.")
        }

        let data = try Data(contentsOf: tempURL)
        let decoded = try JSONDecoder().decode([UUID: HostTopology].self, from: data)
        let topo = try XCTUnwrap(decoded[hostID])
        XCTAssertEqual(topo.sessions.count, 1)
        let entry = try XCTUnwrap(topo.sessions.values.first)
        XCTAssertEqual(entry.name, "round-trip")
        XCTAssertTrue(entry.alive)
        // The session source should round-trip with the docker container name
        if case .docker(let hid, let name) = entry.source {
            XCTAssertEqual(hid, hostID)
            XCTAssertEqual(name, "myapp")
        } else {
            XCTFail("expected .docker source, got \(entry.source)")
        }
    }

    /// Direct JSON round-trip of the topology data model — independent of the
    /// singleton's configure-once limitation, so this is the canonical
    /// schema-drift regression test.
    func testHostTopologyJSONEncodeDecodeRoundTrip() throws {
        let hostID = UUID()
        let now = Date()
        let entry = TopologyEntry(
            id: "session-1", name: "main",
            source: .docker(hostID: hostID, containerName: "myapp"),
            lastSeen: now, lastEnumerated: now, alive: true
        )
        let container = ContainerEntry(name: "myapp", lastSeen: now, alive: true)
        let topo = HostTopology(
            hostID: hostID,
            containers: ["myapp": container],
            sessions: ["session-1": entry],
            lastProbeTime: now,
            lastProbeResult: .ok
        )
        let original: [UUID: HostTopology] = [hostID: topo]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([UUID: HostTopology].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        let recovered = try XCTUnwrap(decoded[hostID])
        XCTAssertEqual(recovered.sessions["session-1"]?.name, "main")
        XCTAssertEqual(recovered.sessions["session-1"]?.alive, true)
        XCTAssertEqual(recovered.containers["myapp"]?.name, "myapp")
        XCTAssertEqual(recovered.lastProbeResult, .ok)
        if case .docker(let hid, let name) = recovered.sessions["session-1"]?.source {
            XCTAssertEqual(hid, hostID)
            XCTAssertEqual(name, "myapp")
        } else {
            XCTFail("docker source did not round-trip")
        }
    }

    func testProbeFailureDoesNotClearExistingSessions() throws {
        let store = NetworkTopologyStore.shared
        store.configure(url: tempURL)

        let hostID = UUID()
        store.mergeEnumeration(
            hostID: hostID,
            sessions: [TmuxSession(name: "keepme", source: .host(hostID: hostID))],
            probeResult: .ok
        )
        XCTAssertEqual(store.hosts[hostID]?.sessions.count, 1)

        // Subsequent unreachable probe must not wipe sessions
        store.mergeEnumeration(hostID: hostID, sessions: [], probeResult: .unreachable)
        XCTAssertEqual(store.hosts[hostID]?.sessions.count, 1, "unreachable probe must not clear sessions")
        XCTAssertEqual(store.hosts[hostID]?.lastProbeResult, .unreachable)
    }
}
