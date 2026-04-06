import XCTest
@testable import OnyxLib

// MARK: - Network Topology Store Tests

final class NetworkTopologyStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkTopologyStore.shared.reset()
    }

    private let hostID = UUID()

    private func makeSession(name: String, source: SessionSource? = nil) -> TmuxSession {
        TmuxSession(name: name, source: source ?? .host(hostID: hostID))
    }

    func testMergeEnumeration_addsNewSessions() {
        let store = NetworkTopologyStore.shared
        let sessions = [makeSession(name: "main"), makeSession(name: "dev")]

        store.mergeEnumeration(hostID: hostID, sessions: sessions, probeResult: .ok)

        XCTAssertEqual(store.hosts[hostID]?.sessions.count, 2)
        XCTAssertTrue(store.hosts[hostID]?.sessions.values.allSatisfy(\.alive) ?? false)
    }

    func testMergeEnumeration_gracePeriod() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "main")

        // First enumeration: session exists
        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)
        XCTAssertTrue(store.hosts[hostID]!.sessions[session.id]!.alive)

        // Second enumeration (immediately): session missing, still within grace period
        store.mergeEnumeration(hostID: hostID, sessions: [], probeResult: .ok)
        // Should still be alive because lastSeen is recent (< 30s)
        XCTAssertTrue(store.hosts[hostID]!.sessions[session.id]!.alive)
    }

    func testMergeEnumeration_marksDeadAfterGrace() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "main")

        // First enumeration
        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Manually backdate lastSeen to simulate time passing
        store.hosts[hostID]!.sessions[session.id]!.lastSeen = Date().addingTimeInterval(-60)

        // Second enumeration: session missing, past grace period
        store.mergeEnumeration(hostID: hostID, sessions: [], probeResult: .ok)
        XCTAssertFalse(store.hosts[hostID]!.sessions[session.id]!.alive)
    }

    func testMergeEnumeration_unreachableHostPreservesEntries() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "main")

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)
        XCTAssertTrue(store.hosts[hostID]!.sessions[session.id]!.alive)

        // Host becomes unreachable — entries should NOT be touched
        store.mergeEnumeration(hostID: hostID, sessions: [], probeResult: .unreachable)
        XCTAssertTrue(store.hosts[hostID]!.sessions[session.id]!.alive)
    }

    func testDeriveSessions_aliveSessions() {
        let store = NetworkTopologyStore.shared
        let sessions = [makeSession(name: "main"), makeSession(name: "dev")]

        store.mergeEnumeration(hostID: hostID, sessions: sessions, probeResult: .ok)

        let derived = store.deriveSessions()
        XCTAssertEqual(derived.count, 2)
        XCTAssertTrue(derived.allSatisfy { !$0.unavailable })
    }

    func testDeriveSessions_recentlyDeadShowAsUnavailable() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "main")

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Mark dead but recently seen (within 10 min)
        store.hosts[hostID]!.sessions[session.id]!.alive = false
        store.hosts[hostID]!.sessions[session.id]!.lastSeen = Date().addingTimeInterval(-300) // 5 min ago

        let derived = store.deriveSessions()
        XCTAssertEqual(derived.count, 1)
        XCTAssertTrue(derived[0].unavailable)
    }

    func testDeriveSessions_oldDeadSessionsHidden() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "main")

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Mark dead and old (> 10 min)
        store.hosts[hostID]!.sessions[session.id]!.alive = false
        store.hosts[hostID]!.sessions[session.id]!.lastSeen = Date().addingTimeInterval(-700)

        let derived = store.deriveSessions()
        XCTAssertEqual(derived.count, 0)
    }

    func testConfirmContainersAlive_refreshesSessions() {
        let store = NetworkTopologyStore.shared
        let container = "nginx"
        let session = TmuxSession(name: "main", source: .docker(hostID: hostID, containerName: container))

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Backdate to simulate staleness
        store.hosts[hostID]!.sessions[session.id]!.lastSeen = Date().addingTimeInterval(-120)

        // Docker stats confirms container alive
        store.confirmContainersAlive(hostID: hostID, containerNames: [container])

        // Session should be refreshed
        let entry = store.hosts[hostID]!.sessions[session.id]!
        XCTAssertTrue(entry.alive)
        XCTAssertTrue(Date().timeIntervalSince(entry.lastSeen) < 2)
    }

    func testGC_removesOldEntries() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "old")

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Backdate to > 24h
        store.hosts[hostID]!.sessions[session.id]!.lastSeen = Date().addingTimeInterval(-90000)

        store.gc()

        XCTAssertEqual(store.hosts[hostID]?.sessions.count, 0)
    }

    func testGC_keepsRecentEntries() {
        let store = NetworkTopologyStore.shared
        let session = makeSession(name: "recent")

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        store.gc()

        XCTAssertEqual(store.hosts[hostID]?.sessions.count, 1)
    }

    func testContainerConfidence_freshIsHigh() {
        let store = NetworkTopologyStore.shared
        let session = TmuxSession(name: "main", source: .docker(hostID: hostID, containerName: "web"))

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        let confidence = store.containerConfidence(hostID: hostID, containerName: "web")
        XCTAssertEqual(confidence, 1.0)
    }

    func testContainerConfidence_staleIsLow() {
        let store = NetworkTopologyStore.shared
        let session = TmuxSession(name: "main", source: .docker(hostID: hostID, containerName: "web"))

        store.mergeEnumeration(hostID: hostID, sessions: [session], probeResult: .ok)

        // Backdate container
        store.hosts[hostID]!.containers["web"]!.lastSeen = Date().addingTimeInterval(-400)

        let confidence = store.containerConfidence(hostID: hostID, containerName: "web")
        XCTAssertTrue(confidence < 0.5)
        XCTAssertTrue(confidence > 0)
    }

    func testProbeStatus_tracksResult() {
        let store = NetworkTopologyStore.shared

        store.mergeEnumeration(hostID: hostID, sessions: [], probeResult: .unreachable)

        let (result, time) = store.probeStatus(hostID: hostID)
        XCTAssertEqual(result, .unreachable)
        XCTAssertNotNil(time)
    }
}

