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

    /// Find every `ssh` process currently running with a `ControlPath`
    /// argument matching the given prefix (typically `~/.ssh/onyx-mux/`).
    /// Returns (pid, controlPath) tuples. Used by the keeper's orphan
    /// reaper — any master whose ControlPath we no longer recognize
    /// gets SIGKILLed because it's holding a remote TCP connection
    /// without serving any of our current sessions.
    ///
    /// Critically, this finds processes even when their socket file has
    /// been unlinked — which is exactly the leak case: we removed the
    /// socket file from disk, but the master process is stuck in a
    /// syscall and hasn't reaped, so it's still holding the connection.
    public static func findAllSSHMastersInDir(_ prefix: String) -> [(pid: pid_t, controlPath: String)] {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,args="]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }

        let watchdog = DispatchQueue.global(qos: .userInitiated)
        let pid = ps.processIdentifier
        let killer = DispatchSource.makeTimerSource(queue: watchdog)
        killer.schedule(deadline: .now() + 3)
        killer.setEventHandler { if ps.isRunning { _ = kill(pid, SIGKILL) } }
        killer.resume()
        ps.waitUntilExit()
        killer.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return [] }

        // Each line: "<pid> <command line>". We want the lines that
        // (a) have `ssh` as the program, AND (b) reference a control
        // path under `prefix`. Pull the actual ControlPath value out
        // for the caller.
        var result: [(pid_t, String)] = []
        for line in str.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(of: " "),
                  let pidNum = Int32(trimmed[..<firstSpace]) else { continue }
            let args = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
            // Quick filters before regex/range work.
            guard args.contains(prefix) else { continue }
            guard args.contains("ssh") else { continue }
            // Extract the ControlPath value. Format is either
            //   `ControlPath=<path>`   (with -o ControlPath=…)
            //   or `ControlPath <path>` (rare). We look for the first
            // occurrence and read until whitespace.
            guard let cpRange = args.range(of: "ControlPath=") else { continue }
            let after = args[cpRange.upperBound...]
            let endIdx = after.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? after.endIndex
            let controlPath = String(after[..<endIdx])
            result.append((pidNum, controlPath))
        }
        return result
    }

    /// SIGKILL a process and verify it actually died. Returns true if
    /// the process is gone within `timeoutMs`. Used by the keeper to
    /// know when a master is genuinely-leaked-and-stuck (kernel queued
    /// the signal but the process is sleeping uninterruptibly in a
    /// syscall) vs successfully reaped.
    public static func killAndVerify(pid: pid_t, timeoutMs: Int = 500) -> Bool {
        _ = kill(pid, SIGKILL)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                // ESRCH (3): no such process. Cleanly reaped.
                return errno == ESRCH
            }
            usleep(20_000)  // 20ms
        }
        return false
    }
}
