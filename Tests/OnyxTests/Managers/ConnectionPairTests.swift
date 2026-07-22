import XCTest
@testable import OnyxLib

/// Drives the ConnectionPair state machine with a scripted runner —
/// no real ssh processes. Locks the promotion / rebuild / rotation /
/// health-derivation behavior that the whole app depends on.
final class ConnectionPairTests: XCTestCase {

    // MARK: Stub runner

    /// Simulated remote: socket paths that "exist", respond to -O check,
    /// and pass smoke tests are tracked as sets the test mutates to
    /// simulate failures.
    final class StubRunner: PairSSHRunner {
        var sockets: Set<String> = []
        var checkAlive: Set<String> = []
        var smokeOK: Set<String> = []
        var establishSucceeds = true
        var establishCount = 0
        var stoppedPaths: [String] = []

        private let ok = SSHProcess.RunResult(exit: 0, stderr: "", timedOut: false)
        private let fail = SSHProcess.RunResult(exit: 255, stderr: "", timedOut: false)

        private func controlPath(in args: [String]) -> String {
            args.first(where: { $0.hasPrefix("ControlPath=") })
                .map { String($0.dropFirst("ControlPath=".count)) } ?? ""
        }

        func run(_ args: [String], softTimeout: TimeInterval, captureStderr: Bool) -> SSHProcess.RunResult {
            let path = controlPath(in: args)
            if args.contains("-M") {
                establishCount += 1
                if establishSucceeds {
                    sockets.insert(path)
                    checkAlive.insert(path)
                    smokeOK.insert(path)
                    return ok
                }
                return fail
            }
            if args.contains("exit") {
                stoppedPaths.append(path)
                sockets.remove(path)
                checkAlive.remove(path)
                smokeOK.remove(path)
                return ok
            }
            if args.contains("check") {
                return checkAlive.contains(path) ? ok : fail
            }
            if args.last == "true" {
                return smokeOK.contains(path) ? ok : fail
            }
            return ok
        }

        func findMasterPID(socketPath: String) -> pid_t? { nil }
        func killAndVerify(pid: pid_t) -> Bool { true }
        func killMaster(at path: String, userHost: String) {}
        func socketExists(atPath path: String) -> Bool { sockets.contains(path) }
        func removeSocket(atPath path: String) { sockets.remove(path) }
        func processAlive(pid: pid_t) -> Bool { false }
    }

    private func makePair() -> (ConnectionPair, StubRunner, HostConfig) {
        let host = HostConfig(
            label: "test",
            ssh: SSHConfig(host: "example.com", user: "u", port: 22, tmuxSession: "main")
        )
        let runner = StubRunner()
        let pair = ConnectionPair(host: host, runner: runner)
        return (pair, runner, host)
    }

    private func slotPaths(for host: HostConfig) -> (String, String) {
        (ConnectionPair.slotPath(for: host.id, slot: 0),
         ConnectionPair.slotPath(for: host.id, slot: 1))
    }

    // MARK: Establishment

    func testFirstMaintain_establishesBothSlots_healthConnected() {
        let (pair, runner, _) = makePair()
        XCTAssertEqual(pair.health.state, .connecting)

        pair.maintain()

        XCTAssertEqual(runner.establishCount, 2)
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
        XCTAssertEqual(pair.health.standbySlotPhase, .alive)
    }

    func testEstablishFailure_staysConnecting_retriesNextMaintain() {
        let (pair, runner, _) = makePair()
        runner.establishSucceeds = false

        pair.maintain()
        XCTAssertEqual(pair.health.state, .connecting)

        runner.establishSucceeds = true
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)
    }

    // MARK: Promotion

    func testActiveDies_standbyPromoted_zeroDowntime() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)
        XCTAssertEqual(pair.activeControlPath, slot0)

        // Simulate silent death of the active master's TCP connection.
        runner.checkAlive.remove(slot0)
        runner.smokeOK.remove(slot0)

        pair.maintain()

        // Standby promoted; dead slot rebuilt in the same maintain pass.
        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
    }

    func testPromotion_bumpsGeneration() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let genBefore = pair.health.generation
        let (slot0, _) = slotPaths(for: host)
        runner.checkAlive.remove(slot0)
        runner.smokeOK.remove(slot0)

        pair.maintain()

        XCTAssertGreaterThan(pair.health.generation, genBefore)
    }

    func testBothDie_afterConnect_healthDown_thenRecovers() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // Kill both and make re-establish fail (host unreachable).
        runner.establishSucceeds = false
        runner.checkAlive.removeAll()
        runner.smokeOK.removeAll()
        runner.sockets.removeAll()
        _ = (slot0, slot1)

        pair.maintain()
        XCTAssertEqual(pair.health.state, .down)

        // Host comes back.
        runner.establishSucceeds = true
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)
    }

    // MARK: Smoke test & channel-failure signals

    func testSmokeFailure_marksDead_promotes() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // Socket answers -O check but real commands hang: silent TCP death.
        runner.smokeOK.remove(slot0)

        // Advance past the smoke-test interval so slot0 is re-tested.
        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.smokeTestInterval + 1))

        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
    }

    func testChannelFailureSignal_promotesImmediately() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // The active socket still passes -O check, but a caller's channel
        // request failed and real commands hang.
        runner.smokeOK.remove(slot0)
        pair.signalChannelFailure()

        // Suspect slots are re-smoke-tested immediately — no waiting for
        // the smoke cadence.
        pair.maintain()

        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.state, .connected)
    }

    // MARK: Rotation

    func testRotation_swapsSlots_whenNoTerminalsAttached() {
        let (pair, runner, host) = makePair()
        pair.terminalChannelCount = { 0 }
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)
        XCTAssertEqual(pair.activeControlPath, slot0)
        _ = runner

        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.rotationInterval + 1))

        XCTAssertEqual(pair.activeControlPath, slot1)
        // Old active was torn down and re-established fresh in the same pass.
        XCTAssertEqual(pair.health.state, .connected)
    }

    func testRotation_skipped_whileTerminalsAttached() {
        let (pair, _, host) = makePair()
        pair.terminalChannelCount = { 3 }
        pair.maintain()
        let (slot0, _) = slotPaths(for: host)

        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.rotationInterval + 1))

        // Rotation is a planned failover — never under live terminals.
        XCTAssertEqual(pair.activeControlPath, slot0)
    }

    // MARK: Sleep / network overrides

    func testQuiesce_stopsMasters_healthSleeping() {
        let (pair, runner, _) = makePair()
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)

        pair.quiesce()

        XCTAssertEqual(pair.health.state, .sleeping)
        XCTAssertTrue(runner.checkAlive.isEmpty, "masters must be cleanly exited on sleep")

        // Maintain during sleep must not establish anything.
        let before = runner.establishCount
        pair.maintain()
        XCTAssertEqual(runner.establishCount, before)
    }

    func testReactivate_rebuildsAfterSleep() {
        let (pair, _, _) = makePair()
        pair.maintain()
        pair.quiesce()

        pair.reactivate()
        pair.maintain()

        XCTAssertEqual(pair.health.state, .connected)
    }

    func testNetworkUnavailable_healthOffline_noEstablishAttempts() {
        let (pair, runner, _) = makePair()
        pair.maintain()
        pair.setNetworkAvailable(false)
        XCTAssertEqual(pair.health.state, .offline)

        let before = runner.establishCount
        pair.maintain()
        XCTAssertEqual(runner.establishCount, before, "no establish attempts while offline")

        pair.setNetworkAvailable(true)
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)
    }

    // MARK: Shutdown

    func testShutdown_stopsBothMasters() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        pair.shutdown()

        XCTAssertTrue(runner.stoppedPaths.contains(slot0))
        XCTAssertTrue(runner.stoppedPaths.contains(slot1))
        XCTAssertTrue(runner.checkAlive.isEmpty)
    }

    // MARK: Channel budget

    func testChannelBudget_dedupsInFlightLabel() {
        let budget = ChannelBudget(maxConcurrent: 2)
        XCTAssertTrue(budget.acquire("monitor:host1"))
        XCTAssertFalse(budget.acquire("monitor:host1"), "identical in-flight poll must be dropped")
        budget.release("monitor:host1")
        XCTAssertTrue(budget.acquire("monitor:host1"))
    }

    func testChannelBudget_capsConcurrency() {
        let budget = ChannelBudget(maxConcurrent: 2)
        XCTAssertTrue(budget.acquire("a"))
        XCTAssertTrue(budget.acquire("b"))
        XCTAssertFalse(budget.acquire("c"), "third concurrent utility channel must be refused")
        budget.release("a")
        XCTAssertTrue(budget.acquire("c"))
    }
}
