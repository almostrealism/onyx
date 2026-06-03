//
// SSHProcess.swift
//
// Responsibility: A single, shared, bulletproof way to run `ssh` (and
//                 helpers like lsof) with HARD wall-clock bounds and
//                 to find/kill orphaned mux master processes.
// Scope: Stateless service.
// Threading: All operations are blocking-but-bounded; safe to call from
//            any thread.
//
// Background: every "ssh hangs the app" pathology we've seen — the
// dispatch-thread-pool exhaustion that needed force-quit, the leaked
// long-running notty sessions on the remote, the supervisors silently
// stuck on Process.waitUntilExit() — has the same root cause: `ssh` in
// some blocking syscall ignores SIGTERM. `Process.terminate()` is
// therefore not a kill; it's a polite request. The only reliable
// termination is SIGKILL after a guarded timeout, which is what this
// module provides.
//

import Foundation
import Darwin

public enum SSHProcess {

    /// Result of a bounded ssh run.
    public struct RunResult {
        public let exit: Int32          // -1 if launch failed or process was killed
        public let stderr: String       // captured only if requested
        public let timedOut: Bool       // true if SIGTERM/SIGKILL was used
    }

    /// Run `/usr/bin/ssh` with the given args, killing it hard if it
    /// exceeds `softTimeout`. SIGTERM at softTimeout, SIGKILL one
    /// second later. `waitUntilExit()` is GUARANTEED to return within
    /// softTimeout + ~1 second.
    @discardableResult
    public static func run(_ args: [String],
                           softTimeout: TimeInterval,
                           captureStderr: Bool = false) -> RunResult {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = captureStderr ? errPipe : FileHandle.nullDevice

        guard (try? process.run()) != nil else {
            return RunResult(exit: -1,
                             stderr: "process failed to launch",
                             timedOut: false)
        }

        let timedOutBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        timedOutBox.initialize(to: 0)
        defer { timedOutBox.deinitialize(count: 1); timedOutBox.deallocate() }

        let pid = process.processIdentifier
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

        var stderrStr = ""
        if captureStderr {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            stderrStr = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return RunResult(exit: process.terminationStatus,
                         stderr: stderrStr,
                         timedOut: timedOutBox.pointee != 0)
    }

    /// Definitively close a mux master listening on `socketPath`. Tries
    /// the clean way (`ssh -O exit`) first, then escalates to finding
    /// the owning PID via `lsof` and SIGKILLing it, then removes the
    /// socket file. After this returns, no master process holds the
    /// remote TCP connection open.
    ///
    /// This is what prevents the long-running orphan masters seen on
    /// the remote host as 30+ hour-old `notty` sessions.
    public static func killMaster(at socketPath: String, userHost: String) {
        // Step 1: clean exit. May fail if the master is unresponsive.
        if FileManager.default.fileExists(atPath: socketPath) {
            _ = run(["-o", "ControlPath=\(socketPath)",
                     "-O", "exit",
                     userHost],
                    softTimeout: 2)
        }

        // Step 2: if the socket still exists OR the process is still
        // running, find it via lsof and SIGKILL it.
        let pids = findMasterPIDs(socketPath: socketPath)
        for pid in pids {
            _ = kill(pid, SIGKILL)
        }
        if !pids.isEmpty {
            // Give the kernel a moment to reap before we delete the
            // socket file (avoids a brief window where another process
            // could see the orphan path).
            usleep(100_000)
        }

        // Step 3: nuke the socket file in case the master left it.
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Find any process holding the given socket path. Uses lsof -t for
    /// a clean numeric PID list. Empty result means no live owner.
    public static func findMasterPIDs(socketPath: String) -> [pid_t] {
        guard FileManager.default.fileExists(atPath: socketPath) else { return [] }
        let lsofProcess = Process()
        let pipe = Pipe()
        lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofProcess.arguments = ["-t", "--", socketPath]
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = FileHandle.nullDevice

        guard (try? lsofProcess.run()) != nil else { return [] }

        // Bound lsof too — it can hang on a stuck socket.
        let pid = lsofProcess.processIdentifier
        let watchdog = DispatchQueue.global(qos: .userInitiated)
        let killer = DispatchSource.makeTimerSource(queue: watchdog)
        killer.schedule(deadline: .now() + 2)
        killer.setEventHandler { if lsofProcess.isRunning { _ = kill(pid, SIGKILL) } }
        killer.resume()
        lsofProcess.waitUntilExit()
        killer.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        return str.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}
