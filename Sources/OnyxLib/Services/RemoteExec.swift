//
// RemoteExec.swift
//
// Responsibility: THE single way to spawn any process that talks to a
//                 remote host — ssh, scp, nc, ssh -O check, you name it.
//                 Maintains a registry of every PID we've spawned so a
//                 single orphan-reap call can definitively clean up
//                 EVERY child we've ever created, regardless of which
//                 area of the code spawned it.
// Scope: Shared singleton.
// Threading: Lock-guarded registry. Run methods are blocking-but-bounded;
//            safe to call from any thread.
//
// Background: prior to this, ssh / scp / nc invocations were scattered
// across AppState, TerminalSessionManager, FileBrowserManager,
// MonitorManager, DockerStats, CPUFleetPoller, GitManager,
// DependencyAnalyzer, and SSHKeeper. Each site rolled its own
// Process+kill-timer pattern. Several only sent SIGTERM (which ssh
// ignores in many states), several didn't time out at all, and NONE
// tracked the spawned PIDs in a central registry. The orphan reaper
// could only find ssh processes via ps-scan filtered for
// `ControlPath=*/onyx-mux/*` — invisible to it: every scp, every nc,
// every interactive session, every probe ssh without ControlPath.
//
// Funnelling everything through RemoteExec means:
//   1. Every short-lived call is wall-clock bounded with SIGKILL
//      escalation (impossible to hang a worker thread).
//   2. Every PID we ever launch goes into `tracked`, so reapAll() is
//      authoritative — no scraping ps for guesses, just kill what we
//      remember spawning.
//   3. Long-lived processes (mux masters, interactive sessions) get
//      registered too; they unregister when the caller signals
//      they're done.
//   4. Inventory dumps surface what's *actually* alive vs what the
//      keeper *thinks* is alive — which were diverging in practice.
//

import Foundation
import Darwin

public final class RemoteExec {

    public static let shared = RemoteExec()

    /// Result of a bounded process run.
    public struct RunResult {
        public let exit: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
    }

    /// One tracked PID. Long-lived ones (mux master, tmux session) stay
    /// in the registry until the caller explicitly unregisters; short-
    /// lived ones unregister automatically when `run` returns.
    public struct TrackedProcess: Equatable {
        public let pid: pid_t
        public let label: String          // free-form e.g. "ssh probe alpha"
        public let spawnedAt: Date
        public let longLived: Bool
    }

    private var tracked: [pid_t: TrackedProcess] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Spawning

    /// Run an arbitrary executable with HARD bounds. Soft timeout fires
    /// SIGTERM; SIGKILL goes one second after. `waitUntilExit()` is
    /// guaranteed to return within `softTimeout + ~1s`. PID is
    /// registered in `tracked` for the duration of the run.
    ///
    /// `label` should be short and descriptive — appears in
    /// `inventory()` dumps to help identify leaks.
    @discardableResult
    public func run(_ executablePath: String,
                    args: [String],
                    stdin: String? = nil,
                    softTimeout: TimeInterval,
                    captureStdout: Bool = false,
                    captureStderr: Bool = false,
                    label: String) -> RunResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = stdin.map { _ in Pipe() }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        process.standardOutput = captureStdout ? outPipe : FileHandle.nullDevice
        process.standardError = captureStderr ? errPipe : FileHandle.nullDevice
        if let inPipe = inPipe { process.standardInput = inPipe }

        guard (try? process.run()) != nil else {
            return RunResult(exit: -1,
                             stdout: "",
                             stderr: "process failed to launch",
                             timedOut: false)
        }

        let pid = process.processIdentifier
        register(pid: pid, label: label, longLived: false)
        defer { unregister(pid: pid) }

        // Feed stdin if requested.
        if let inPipe = inPipe, let s = stdin, let data = s.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }

        // Watchdogs — soft (SIGTERM) at the budget, hard (SIGKILL) 1s later.
        let timedOutBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        timedOutBox.initialize(to: 0)
        defer { timedOutBox.deinitialize(count: 1); timedOutBox.deallocate() }

        let watchdog = DispatchQueue.global(qos: .userInitiated)
        let soft = DispatchSource.makeTimerSource(queue: watchdog)
        soft.schedule(deadline: .now() + softTimeout)
        soft.setEventHandler {
            if process.isRunning {
                timedOutBox.pointee = 1
                _ = kill(pid, SIGTERM)
            }
        }
        soft.resume()

        let hard = DispatchSource.makeTimerSource(queue: watchdog)
        hard.schedule(deadline: .now() + softTimeout + 1)
        hard.setEventHandler {
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
        hard.resume()

        process.waitUntilExit()
        soft.cancel()
        hard.cancel()

        var stdoutStr = ""
        var stderrStr = ""
        if captureStdout {
            stdoutStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        }
        if captureStderr {
            stderrStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
            stderrStr = stderrStr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return RunResult(exit: process.terminationStatus,
                         stdout: stdoutStr,
                         stderr: stderrStr,
                         timedOut: timedOutBox.pointee != 0)
    }

    // MARK: - Convenience wrappers (typed for the common cases)

    /// `ssh` short-lived utility command. Forwards to `run` with the
    /// system ssh executable.
    @discardableResult
    public func ssh(args: [String],
                    stdin: String? = nil,
                    softTimeout: TimeInterval = 10,
                    captureStdout: Bool = false,
                    captureStderr: Bool = false,
                    label: String) -> RunResult {
        run("/usr/bin/ssh", args: args, stdin: stdin,
            softTimeout: softTimeout,
            captureStdout: captureStdout, captureStderr: captureStderr,
            label: "ssh:\(label)")
    }

    /// `scp` file transfer. Slightly longer default timeout because
    /// transfers naturally take longer than a single ssh command.
    @discardableResult
    public func scp(args: [String],
                    softTimeout: TimeInterval = 30,
                    captureStderr: Bool = false,
                    label: String) -> RunResult {
        run("/usr/bin/scp", args: args, stdin: nil,
            softTimeout: softTimeout,
            captureStdout: false, captureStderr: captureStderr,
            label: "scp:\(label)")
    }

    /// `nc` reachability probe (TCP port check). Returns true if the
    /// port accepted a connection within the budget.
    public func ncReachable(host: String,
                            port: Int,
                            timeout: Int = 3) -> Bool {
        let r = run("/usr/bin/nc",
                    args: ["-z", "-w", "\(timeout)", host, "\(port)"],
                    stdin: nil,
                    softTimeout: TimeInterval(timeout) + 1,
                    captureStdout: false, captureStderr: false,
                    label: "nc:\(host):\(port)")
        return r.exit == 0
    }

    // MARK: - Registry (long-lived process tracking)

    /// Register a PID we own. Idempotent. `longLived = true` means we
    /// won't auto-unregister; the caller must call `unregister` when
    /// the process dies or is no longer wanted (mux masters,
    /// interactive sessions).
    public func register(pid: pid_t, label: String, longLived: Bool) {
        guard pid > 0 else { return }
        lock.lock()
        tracked[pid] = TrackedProcess(
            pid: pid, label: label, spawnedAt: Date(), longLived: longLived
        )
        lock.unlock()
    }

    public func unregister(pid: pid_t) {
        guard pid > 0 else { return }
        lock.lock()
        tracked.removeValue(forKey: pid)
        lock.unlock()
    }

    // MARK: - Inventory + reap

    /// Snapshot of every PID we currently track.
    public func snapshot() -> [TrackedProcess] {
        lock.lock(); defer { lock.unlock() }
        return Array(tracked.values).sorted { $0.spawnedAt < $1.spawnedAt }
    }

    /// SIGKILL every tracked PID (long-lived OR in-flight). Bounded by
    /// `SSHProcess.killAndVerify`. Returns (killed, refused) where
    /// refused are PIDs stuck in uninterruptible kernel sleep that
    /// even SIGKILL couldn't reach within the verify window.
    @discardableResult
    public func reapAll() -> (killed: Int, refused: Int) {
        let snapshot = self.snapshot()
        var killed = 0
        var refused = 0
        for p in snapshot {
            if SSHProcess.killAndVerify(pid: p.pid) {
                killed += 1
            } else {
                refused += 1
            }
            // Whether killed or not, drop it from the registry — the
            // process will eventually be reaped by the kernel and we
            // don't want to keep retrying it forever.
            unregister(pid: p.pid)
        }
        return (killed, refused)
    }

    /// Human-readable inventory of every tracked PID. Used by the
    /// diagnostic UI's "Copy inventory" action.
    public func inventoryDump() -> String {
        let snapshot = self.snapshot()
        if snapshot.isEmpty { return "  (no tracked processes)" }
        let now = Date()
        return snapshot.map { p in
            let age = Int(now.timeIntervalSince(p.spawnedAt))
            let kind = p.longLived ? "[long]" : "[short]"
            return "  pid=\(p.pid) age=\(age)s \(kind) \(p.label)"
        }.joined(separator: "\n")
    }
}
