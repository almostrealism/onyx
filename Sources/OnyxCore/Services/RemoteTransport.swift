//
// RemoteTransport.swift
//
// Responsibility: The one seam every remote call goes through — run a
//                 command or a script on a host, move a file to or from
//                 it — whatever actually carries the bytes.
// Scope: Protocol and value types. Implementations: `ProcessTransport`
//        (the Mac's `ssh`/`scp` processes riding the ConnectionPair's
//        ControlMaster sockets) and `NIOTransport` (in-process SSH, the
//        only kind iOS can have). See docs/ios-plan.md, phase 1.
// Threading: Implementations block, bounded by `timeout`; callers run
//            them off the main thread, as they always have.
//
// What belongs in an implementation is only "deliver these bytes, bring
// back what came out". Everything learned about hostile remote shells —
// the completion marker, the pipe-first-terminal-second fallback, reading
// the host's complaint out of stdout — lives HERE, once, so both
// transports get it and neither can drift (CLAUDE.md, "Remote command
// execution").
//

import Foundation

/// How a script reaches the remote shell.
public enum RemoteInvocation: Equatable, Sendable {
    /// An exec request: `exec $SHELL -lc '<command>'`. Fire-and-forget
    /// side effects and simple reads; a noexec login profile defeats it,
    /// which those callers accept (see `remoteCommand`).
    case command(String)
    /// A shell request, the wrapped script (`RemoteScript.wrap`) on
    /// stdin. `terminal` allocates a PTY: the interactive shell that
    /// ignores `set -n`, with the ~1KB input queue that comes with it.
    case script(String, terminal: Bool)
}

/// What came back. stdout and stderr stay apart here; `combined` is the
/// merged form the script parsers have always read.
public struct RemoteOutput: Equatable, Sendable {
    public let exit: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(exit: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exit = exit
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// stdout, then stderr on its own line — the contract every script
    /// caller was written against.
    public var combined: String {
        stdout + (stderr.isEmpty ? "" : "\n" + stderr)
    }

    /// A transport that couldn't even start (no connection, no process).
    public static func failed(_ why: String) -> RemoteOutput {
        RemoteOutput(exit: -1, stdout: "", stderr: why, timedOut: false)
    }

    /// ssh's own failure code: the connection, not the command.
    public var isTransportFailure: Bool { exit == 255 }
}

/// What a script run actually produced, failure included.
///
/// Collapsing every failure to nil is fine for callers that just keep
/// stale data — but then nobody can say WHY it failed. That is how the git
/// panel spent months absent with no explanation available anywhere.
/// Callers that show the user something should report `failureDetail`.
public struct RemoteRun: Sendable {
    /// Cleaned output, or nil when the script didn't verifiably run.
    public let cleaned: String?
    public let exitCode: Int32
    public let timedOut: Bool
    /// The remote's own words, when it said anything.
    public let hostSaid: String?
    /// Did any output arrive at all?
    public let hadOutput: Bool
    /// How much came back, and the start of it (control sequences
    /// stripped, newlines flattened). "A login banner then silence" and
    /// "our own script echoed back but never ran" are indistinguishable
    /// without this, and they point at completely different faults.
    public let byteCount: Int
    public let preview: String

    public init(_ output: RemoteOutput) {
        let raw = output.combined
        let verified = RemoteScript.executionVerified(in: raw)
        let flattened = RemoteScript.stripControlSequences(
            raw.replacingOccurrences(of: "\r", with: "\n"))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        cleaned = verified ? RemoteScript.cleanedOutput(raw) : nil
        exitCode = output.exit
        timedOut = output.timedOut
        hostSaid = RemoteScript.remoteComplaint(in: raw)
        hadOutput = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        byteCount = raw.count
        preview = String(flattened.prefix(400))
    }

    /// One line naming what went wrong, in the host's words where possible.
    public var failureDetail: String {
        if timedOut { return "no answer within the time budget" }
        if !hadOutput { return "no output at all (exit \(exitCode))" }
        // Output came back without the completion marker: the session
        // answered but our script never ran to the end. Say THAT — quoting
        // the host's first line alone showed a login banner as though the
        // banner were the error.
        let opening = hostSaid.map { ", starting \"\($0)\"" } ?? ""
        return "the session answered but never ran the script "
            + "(\(byteCount)B back, exit \(exitCode)\(opening))"
    }
}

/// How `runScript` delivers.
public enum ScriptDelivery: Sendable {
    /// A plain pipe first; a terminal only when the completion marker
    /// doesn't come back (the noexec signature). The default for any new
    /// data-reading caller.
    case pipeThenTerminal
    /// Always a terminal.
    case terminal
    /// Never a terminal.
    case pipe
}

/// A remote run that streams: `cancel` ends it early.
public protocol RemoteJob: AnyObject {
    func cancel()
}

public protocol RemoteTransport: AnyObject {
    /// Short name for logs ("openssh", "built-in").
    var name: String { get }

    /// Run one invocation on `host`, bounded by `timeout`.
    func execute(_ invocation: RemoteInvocation, on host: HostConfig,
                 timeout: TimeInterval, label: String) -> RemoteOutput

    /// Start an invocation whose stdout arrives as it is produced (search
    /// results, a log tail). `onOutput` and `onExit` are called on a
    /// background queue; `onExit` exactly once, with the exit status (-1
    /// when it never started). Ended after `timeout` regardless.
    @discardableResult
    func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
               label: String, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) -> RemoteJob

    /// Copy a local file (or, `recursive`, a folder) to `remotePath`.
    ///
    /// Remote paths are SFTP paths, never shell paths: absolute, or
    /// relative to the remote home. `$HOME/x` arrives as four literal
    /// characters (CLAUDE.md, "scp paths are NOT shell paths"). Modification
    /// times are preserved.
    func upload(_ localPath: String, to remotePath: String, on host: HostConfig,
                recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput

    /// Copy `remotePath` (or, `recursive`, a folder) down to `localPath`.
    func download(_ remotePath: String, to localPath: String, from host: HostConfig,
                  recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput
}

public extension RemoteTransport {

    /// Run a script and verify it ran, preferring a pipe over a terminal.
    ///
    /// Order matters and is the whole point:
    ///
    ///   1. No terminal. stdin is a plain pipe — no ~1KB input queue, no
    ///      line discipline, nothing that can truncate or mangle the
    ///      script. This is how a data command SHOULD be delivered, and it
    ///      fixed hosts that were corrupting the payload's tail (the shell
    ///      reported "command not found" for the mangled remainder and
    ///      exited 127, with no completion marker).
    ///
    ///   2. Only if that comes back WITHOUT the completion marker, retry
    ///      with a terminal. A missing marker is the noexec signature —
    ///      the remote profile refusing to execute a non-interactive shell
    ///      — which is precisely what the interactive form defeats. So the
    ///      defense is intact; we just stop paying a terminal's
    ///      constraints for every call on every healthy host.
    ///
    /// Local hosts have neither problem and run once.
    func runScript(_ script: String, on host: HostConfig,
                   delivery: ScriptDelivery = .pipeThenTerminal,
                   timeout: TimeInterval = 10, label: String) -> RemoteRun {
        switch delivery {
        case .terminal:
            return RemoteRun(execute(.script(script, terminal: true), on: host,
                                     timeout: timeout, label: label))
        case .pipe:
            return RemoteRun(execute(.script(script, terminal: false), on: host,
                                     timeout: timeout, label: label))
        case .pipeThenTerminal:
            let first = RemoteRun(execute(.script(script, terminal: false), on: host,
                                          timeout: timeout, label: label))
            if first.cleaned != nil || host.isLocal { return first }
            DiagnosticLog.shared.record("ssh",
                "\(host.label): no marker over a plain pipe — retrying with a terminal")
            let second = RemoteRun(execute(.script(script, terminal: true), on: host,
                                           timeout: timeout, label: label))
            // Report whichever attempt got further, so the failure message
            // describes the better evidence rather than the last try.
            return second.cleaned != nil || second.byteCount >= first.byteCount ? second : first
        }
    }

    /// An exec request (`exec $SHELL -lc '…'`).
    func runCommand(_ command: String, on host: HostConfig,
                    timeout: TimeInterval = 10, label: String) -> RemoteOutput {
        execute(.command(command), on: host, timeout: timeout, label: label)
    }
}
