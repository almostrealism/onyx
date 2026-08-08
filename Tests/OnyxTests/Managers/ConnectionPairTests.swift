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
        // PID simulation: each established master gets a fake PID so the
        // definitive process-exit detector can be exercised.
        var pidCounter: pid_t = 1000
        var pathToPID: [String: pid_t] = [:]
        var deadPIDs: Set<pid_t> = []

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
                    pidCounter += 1
                    pathToPID[path] = pidCounter
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

        func findMasterPID(socketPath: String) -> pid_t? { pathToPID[socketPath] }
        func killAndVerify(pid: pid_t) -> Bool { deadPIDs.insert(pid); return true }
        func killMaster(at path: String, userHost: String) {}
        func socketExists(atPath path: String) -> Bool { sockets.contains(path) }
        func removeSocket(atPath path: String) { sockets.remove(path) }
        func processAlive(pid: pid_t) -> Bool { !deadPIDs.contains(pid) }
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

    func testActiveDies_corroborated_standbyPromoted() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)
        XCTAssertEqual(pair.activeControlPath, slot0)

        // Simulate silent socket-level death of the active master (the
        // process is somehow still around, so only the advisory checks
        // see it). Death requires checkFailureThreshold consecutive
        // failures — never a single sample.
        runner.checkAlive.remove(slot0)
        runner.smokeOK.remove(slot0)

        for _ in 0..<ConnectionPair.checkFailureThreshold {
            pair.maintain()
        }

        // Standby promoted; dead slot rebuilt in the same maintain pass.
        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
    }

    /// THE stable-desktop regression test: one failed -O check (load
    /// spike, slow fork) must NOT kill a working master. Single-sample
    /// kill authority is what ate healthy connections every few hours.
    func testSingleCheckFailure_doesNotKillActive() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, _) = slotPaths(for: host)

        // One transient hiccup...
        runner.checkAlive.remove(slot0)
        pair.maintain()
        // ...then the check recovers.
        runner.checkAlive.insert(slot0)
        pair.maintain()

        XCTAssertEqual(pair.activeControlPath, slot0, "active master must survive a transient hiccup")
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(runner.establishCount, 2, "no rebuild may be triggered by a single failed check")
    }

    /// Definitive evidence path: the master PROCESS exiting (ssh's own
    /// ServerAlive verdict) kills the slot on the very next maintain —
    /// no thresholds, because process death is proof.
    func testMasterProcessExit_diesImmediately_promotes() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // The active master's process exits; its stale socket still
        // answers -O check (worst case).
        if let pid = runner.pathToPID[slot0] { runner.deadPIDs.insert(pid) }
        pair.maintain()

        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
    }

    func testPromotion_bumpsGeneration() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let genBefore = pair.health.generation
        let (slot0, _) = slotPaths(for: host)
        runner.checkAlive.remove(slot0)
        runner.smokeOK.remove(slot0)

        for _ in 0..<ConnectionPair.checkFailureThreshold {
            pair.maintain()
        }

        XCTAssertGreaterThan(pair.health.generation, genBefore)
    }

    func testBothDie_afterConnect_healthDown_thenRecovers() {
        let (pair, runner, _) = makePair()
        pair.maintain()

        // Both master PROCESSES exit (what actually happens when the
        // network dies: ServerAlive fails and ssh exits) and re-establish
        // fails (host unreachable). Process death is definitive — .down
        // on the very next maintain.
        runner.establishSucceeds = false
        runner.deadPIDs.formUnion(runner.pathToPID.values)
        runner.checkAlive.removeAll()
        runner.smokeOK.removeAll()
        runner.sockets.removeAll()

        pair.maintain()
        XCTAssertEqual(pair.health.state, .down)

        // Host comes back.
        runner.establishSucceeds = true
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)
    }

    // MARK: Smoke test & channel-failure signals

    func testSmokeFailure_needsCorroboration_thenPromotes() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // Socket answers -O check but real commands hang: silent TCP death.
        runner.smokeOK.remove(slot0)

        // First failure past the smoke cadence: suspect, NOT dead.
        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.smokeTestInterval + 1))
        XCTAssertEqual(pair.activeControlPath, slot0, "one smoke failure must not kill")

        // Suspect is re-tested immediately on the next maintain; a second
        // consecutive failure is corroboration -> dead -> promote.
        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.smokeTestInterval + 2))
        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.activeSlotPhase, .alive)
    }

    /// A single smoke hiccup that recovers must leave the master alone.
    func testSingleSmokeFailure_recovers_noKill() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, _) = slotPaths(for: host)

        runner.smokeOK.remove(slot0)
        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.smokeTestInterval + 1))
        runner.smokeOK.insert(slot0)
        pair.maintain(now: Date().addingTimeInterval(ConnectionPair.smokeTestInterval + 2))

        XCTAssertEqual(pair.activeControlPath, slot0)
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(runner.establishCount, 2, "no rebuild for a transient smoke failure")
    }

    func testChannelFailureSignal_withHungCommands_promotes() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)

        // The active socket still passes -O check, but a caller's channel
        // request failed AND real commands hang: two independent signals.
        runner.smokeOK.remove(slot0)
        pair.signalChannelFailure()

        // Suspect is smoke-tested immediately (failure 1/2), then
        // re-tested next maintain (failure 2/2) -> dead -> promote.
        pair.maintain()
        pair.maintain()

        XCTAssertEqual(pair.activeControlPath, slot1)
        XCTAssertEqual(pair.health.state, .connected)
    }

    /// An exit-255 report alone (poller failure) against a master whose
    /// commands actually work must NOT kill anything.
    func testChannelFailureSignal_aloneWithHealthyMaster_noKill() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        let (slot0, _) = slotPaths(for: host)

        pair.signalChannelFailure()
        pair.maintain()
        pair.maintain()

        XCTAssertEqual(pair.activeControlPath, slot0)
        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(runner.establishCount, 2)
    }

    // MARK: Rotation

    func testRotation_swapsSlots_whenNoTerminalsAttached() {
        let (pair, runner, host) = makePair()
        pair.terminalChannelCount = { 0 }
        pair.maintain()
        let (slot0, slot1) = slotPaths(for: host)
        XCTAssertEqual(pair.activeControlPath, slot0)
        _ = runner

        // Second maintain starts the rotation clock (pair fully alive);
        // rotation fires only after a full interval from THAT point.
        pair.maintain()
        XCTAssertEqual(pair.activeControlPath, slot0,
                       "rotation must not fire at startup — the clock starts when the pair is first fully alive")

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

    // MARK: Paused hosts

    /// Pausing must close both masters and then cost NOTHING per tick —
    /// the whole point is to stop touching a host that's making the
    /// network worse.
    func testPaused_closesMastersAndNeverReconnects() {
        let (pair, runner, host) = makePair()
        pair.maintain()
        XCTAssertEqual(pair.health.state, .connected)
        let (slot0, slot1) = slotPaths(for: host)

        var paused = host
        paused.paused = true
        pair.configure(host: paused)
        pair.maintain()

        XCTAssertEqual(pair.health.state, .paused)
        XCTAssertFalse(pair.health.state.isUsable)
        XCTAssertTrue(runner.stoppedPaths.contains(slot0))
        XCTAssertTrue(runner.stoppedPaths.contains(slot1))
        XCTAssertTrue(runner.sockets.isEmpty)

        // Subsequent ticks are free: no establish, no further stop calls.
        let establishes = runner.establishCount
        let stops = runner.stoppedPaths.count
        pair.maintain()
        pair.maintain()
        XCTAssertEqual(runner.establishCount, establishes,
                       "a paused host must never be reconnected")
        XCTAssertEqual(runner.stoppedPaths.count, stops,
                       "teardown must happen once, not every tick")
        XCTAssertEqual(pair.health.state, .paused)
    }

    /// A host paused before the first tick never connects at all.
    func testPausedFromTheStart_neverEstablishes() {
        let host = HostConfig(
            label: "test",
            ssh: SSHConfig(host: "example.com", user: "u", port: 22, tmuxSession: "main"),
            paused: true
        )
        let runner = StubRunner()
        let pair = ConnectionPair(host: host, runner: runner)

        pair.maintain()
        pair.maintain()

        XCTAssertEqual(runner.establishCount, 0)
        XCTAssertEqual(pair.health.state, .paused)
    }

    func testUnpause_reconnectsOnNextMaintain() {
        let (pair, runner, host) = makePair()
        var paused = host
        paused.paused = true
        pair.configure(host: paused)
        pair.maintain()
        XCTAssertEqual(pair.health.state, .paused)

        pair.configure(host: host)   // un-paused
        pair.maintain()

        XCTAssertEqual(pair.health.state, .connected)
        XCTAssertEqual(runner.establishCount, 2)
    }

    /// Pause outranks sleep/offline in the reported state: the user set it,
    /// and "sleeping" would imply it comes back on its own.
    func testPaused_outranksOfflineAndSleeping() {
        let (pair, _, host) = makePair()
        var paused = host
        paused.paused = true
        pair.configure(host: paused)
        pair.setNetworkAvailable(false)
        pair.quiesce()

        XCTAssertEqual(pair.health.state, .paused)
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
