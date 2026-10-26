//
// ProcessTransport.swift
//
// Responsibility: The Mac's RemoteTransport: `ssh` and `scp` processes
//                 riding each host's ConnectionPair as mux channels, and
//                 the local shell for the localhost host.
// Scope: One per AppState (`appState.transport`).
// Threading: Blocking and bounded (RemoteExec); call off the main thread.
//
// Nothing new here — this is the command building and process running
// every manager used to do for itself, behind the seam (RemoteTransport,
// docs/ios-plan.md phase 1). The command shapes are still the AppState
// builders that AppStateTests lock down.
//

import Foundation
import OnyxCore

public final class ProcessTransport: RemoteTransport {

    public let name = "openssh"
    private weak var appState: AppState?

    public init(appState: AppState) {
        self.appState = appState
    }

    public func execute(_ invocation: RemoteInvocation, on host: HostConfig,
                        timeout: TimeInterval, label: String) -> RemoteOutput {
        guard let appState else { return .failed("no app state") }
        let cmd: String
        let args: [String]
        var stdin: String?
        switch invocation {
        case .command(let command):
            (cmd, args) = appState.remoteCommand(command, host: host)
        case .script(let script, let terminal):
            (cmd, args, stdin) = terminal
                ? appState.remoteScript(script, host: host)
                : appState.remoteScriptNoTTY(script, host: host)
        }
        return run(cmd, args, stdin: stdin, timeout: timeout, label: label)
    }

    public func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
                      label: String, onOutput: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) -> RemoteJob {
        let job = ProcessJob()
        guard let appState else { onExit(-1); return job }
        let cmd: String
        let args: [String]
        var stdin: String?
        switch invocation {
        case .command(let command):
            (cmd, args) = appState.remoteCommand(command, host: host)
        case .script(let script, let terminal):
            (cmd, args, stdin) = terminal
                ? appState.remoteScript(script, host: host)
                : appState.remoteScriptNoTTY(script, host: host)
        }
        job.start(cmd, args, stdin: stdin, timeout: timeout, label: label,
                  onOutput: onOutput, onExit: onExit)
        return job
    }

    public func upload(_ localPath: String, to remotePath: String, on host: HostConfig,
                       recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        if host.isLocal {
            return run("/bin/cp", (recursive ? ["-R"] : ["-p"]) + [localPath, remotePath],
                       stdin: nil, timeout: timeout, label: label)
        }
        guard let appState else { return .failed("no app state") }
        var (cmd, args) = appState.scpCommand(localPath: localPath, remotePath: remotePath, host: host)
        if recursive { args.insert("-r", at: args.count - 2) }
        return run(cmd, args, stdin: nil, timeout: timeout, label: label)
    }

    public func download(_ remotePath: String, to localPath: String, from host: HostConfig,
                         recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        if host.isLocal {
            return run("/bin/cp", (recursive ? ["-R"] : ["-p"]) + [remotePath, localPath],
                       stdin: nil, timeout: timeout, label: label)
        }
        guard let appState else { return .failed("no app state") }
        var (cmd, args) = appState.scpFetchCommand(remotePath: remotePath, localPath: localPath, host: host)
        if recursive { args.insert("-r", at: args.count - 2) }
        return run(cmd, args, stdin: nil, timeout: timeout, label: label)
    }

    private func run(_ cmd: String, _ args: [String], stdin: String?,
                     timeout: TimeInterval, label: String) -> RemoteOutput {
        let r = RemoteExec.shared.run(cmd, args: args, stdin: stdin, softTimeout: timeout,
                                      captureStdout: true, captureStderr: true, label: label)
        return RemoteOutput(exit: r.exit, stdout: r.stdout, stderr: r.stderr, timedOut: r.timedOut)
    }
}

/// A streaming process: stdout delivered as it arrives, stdin paced (a
/// terminal can't take a script at full speed — RemoteExec.writePaced),
/// tracked by RemoteExec so the reaper can find it.
final class ProcessJob: RemoteJob {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func start(_ cmd: String, _ args: [String], stdin: String?, timeout: TimeInterval,
               label: String, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) {
        let out = Pipe()
        let input: Pipe? = stdin.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        if let input { process.standardInput = input }

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onOutput(text)
        }

        let process = self.process
        let killTimer = DispatchSource.makeTimerSource(queue: .global())
        killTimer.schedule(deadline: .now() + timeout)
        killTimer.setEventHandler { if process.isRunning { process.terminate() } }
        // Resumed at once: a dispatch source released while still
        // suspended crashes the app.
        killTimer.resume()

        // Holds itself until the process is done, so a caller that drops
        // the job (nothing to cancel) still gets its run.
        DispatchQueue.global(qos: .userInitiated).async {
            guard !self.isCancelled, (try? process.run()) != nil else {
                killTimer.cancel()
                out.fileHandleForReading.readabilityHandler = nil
                onExit(-1)
                return
            }
            let pid = process.processIdentifier
            RemoteExec.shared.register(pid: pid, label: label, longLived: false)
            if let input, let data = stdin?.data(using: .utf8) {
                RemoteExec.writePaced(data, to: input.fileHandleForWriting,
                                      while: { process.isRunning })
                try? input.fileHandleForWriting.close()
            }
            process.waitUntilExit()
            killTimer.cancel()
            // Drain what's left before saying it's over.
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty, let text = String(data: rest, encoding: .utf8) { onOutput(text) }
            RemoteExec.shared.unregister(pid: pid)
            onExit(process.terminationStatus)
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        if process.isRunning { process.terminate() }
    }
}
