//
// AppState+SSH.swift
//
// Responsibility: Every command Onyx runs on a host — the mux arguments
//                 the connection pair is built from, the interactive
//                 session commands, the data-reading script wrappers, and
//                 the file transfers.
// Scope: An extension on AppState rather than a type of its own: these
//        need the host list, the active session and the pause flag, and
//        splitting them off behind a protocol would buy indirection and
//        no testability — they are already pure functions of their inputs
//        and `AppStateTests` calls them directly.
//
// Split out of AppState.swift, which had grown past the point where the
// file could be read as one thing. Nothing here changed in the move.
//
// Before adding a builder, read the "Remote command execution" section of
// CLAUDE.md. The traps are real and they fail silently: noexec shells,
// history expansion in interactive zsh, unmatched globs, and a ~1KB
// ceiling on anything fed to a TTY.
//

import Foundation
import AppKit

extension AppState {
    // MARK: - SSH Multiplexing

    /// Directory for SSH mux control sockets.
    /// Must NOT contain spaces — SSH's ControlPath parser splits on whitespace.
    /// Uses ~/.ssh/onyx-mux/ which is guaranteed space-free.
    private var sshMuxDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".ssh/onyx-mux")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// ControlPath pattern for SSH multiplexing. Consults the pair
    /// registry, which maintains an active + standby master per host and
    /// returns whichever slot is currently active. Falls back to the
    /// legacy single-slot path when the pair hasn't been created yet
    /// (e.g. before its first tick).
    func sshControlPath(for host: HostConfig) -> String {
        ConnectionPairRegistry.shared.controlPath(for: host)
    }

    /// SSH multiplexing args for SHORT-LIVED utility commands. Rides the
    /// host's connection pair as a mux channel — `ControlMaster=no` means
    /// a utility command can NEVER spawn its own master; the pair
    /// supervisor owns the only TCP connections to a host (two, ever).
    private func sshMuxArgs(for host: HostConfig) -> [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(sshControlPath(for: host))",
        ]
    }

    /// The bundled MCP bridge for a platform, or nil if this build
    /// doesn't carry one for it.
    ///
    /// Looks in the app bundle first (Contents/Resources/mcp) and then
    /// beside the executable, which is where a `swift build` layout puts
    /// it during development. Bundle.module is deliberately avoided —
    /// referencing it fatalErrors when the resource bundle isn't where
    /// SPM hardcoded it, which is every machine except the one that
    /// compiled the app.
    public func bundledMCPBinary(for platform: RemotePlatform) -> URL? {
        let name = platform.artifactName
        if let url = Bundle.main.url(forResource: name, withExtension: nil,
                                     subdirectory: "mcp") {
            return url
        }
        let beside = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mcp/\(name)")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    /// Which platforms this build can install onto — used to say so
    /// before someone tries.
    public var bundledMCPPlatforms: [RemotePlatform] {
        [RemotePlatform(os: .macOS, arch: "arm64"),
         RemotePlatform(os: .linux, arch: "arm64"),
         RemotePlatform(os: .linux, arch: "x86_64")]
            .filter { bundledMCPBinary(for: $0) != nil }
    }

    /// `scp` a local file to a path relative to the remote home dir.
    ///
    /// Rides the host's connection pair as a mux channel — the same
    /// ControlMaster=no / ControlPath discipline as every other utility
    /// command, so a dropped file can never open a third connection to a
    /// host. `-p` keeps the modification time, which matters when the
    /// thing reading the file is deciding whether it changed.
    public func scpCommand(localPath: String, remotePath: String,
                           host: HostConfig) -> (cmd: String, args: [String]) {
        var args = sshMuxArgs(for: host)
        args.append(contentsOf: ["-o", "BatchMode=yes", "-p", "-q"])
        if host.ssh.port != 22 {
            // scp spells the port -P, not -p. Getting this wrong silently
            // copies to the wrong host on a machine with two SSH daemons.
            args.append(contentsOf: ["-P", "\(host.ssh.port)"])
        }
        if !host.ssh.identityFile.isEmpty {
            args.append(contentsOf: ["-i", host.ssh.identityFile])
        }
        args.append(localPath)
        let target = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
        args.append("\(target):\(remotePath)")
        return ("/usr/bin/scp", args)
    }

    /// Kept as a name for call sites that pass an absolute remote path.
    ///
    /// There is no behavioural difference and there cannot be: scp speaks
    /// SFTP (OpenSSH 9.0+), so the remote path is interpreted by the SFTP
    /// server, not a shell. Absolute paths work, relative ones resolve
    /// against the remote home directory, and SHELL SYNTAX DOES NOT WORK
    /// AT ALL — `$HOME/x` arrives as four literal characters and fails
    /// with "No such file or directory". Use `$HOME` in scripts; use a
    /// relative path here.
    public func scpCommandAbsolute(localPath: String, remotePath: String,
                                   host: HostConfig) -> (cmd: String, args: [String]) {
        scpCommand(localPath: localPath, remotePath: remotePath, host: host)
    }

    /// `scp` the other way — a remote file down to a local path.
    ///
    /// Same flags as the upload, built from the same mux args, so the two
    /// directions can't drift apart on port or identity handling. `-p` is
    /// the port here only via the same `-P` special case; scp's `-p` means
    /// "preserve times", which is why the upload has both.
    public func scpFetchCommand(remotePath: String, localPath: String,
                                host: HostConfig) -> (cmd: String, args: [String]) {
        var args = sshMuxArgs(for: host)
        args.append(contentsOf: ["-o", "BatchMode=yes", "-p", "-q"])
        if host.ssh.port != 22 {
            args.append(contentsOf: ["-P", "\(host.ssh.port)"])
        }
        if !host.ssh.identityFile.isEmpty {
            args.append(contentsOf: ["-i", host.ssh.identityFile])
        }
        let target = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
        args.append("\(target):\(remotePath)")
        args.append(localPath)
        return ("/usr/bin/scp", args)
    }

    /// Report an SSH failure (exit 255) against a host — marks the pair's
    /// active connection suspect so the standby is promoted immediately
    /// instead of waiting for the next smoke test. Replaces the old
    /// markMuxStale socket-deletion dance (which raced its own cleanup).
    public func reportSSHFailure(host: HostConfig?) {
        guard let host, !host.isLocal else { return }
        ConnectionPairRegistry.shared.pair(for: host).signalChannelFailure()
    }

    /// True when the host's connection pair can carry traffic right now.
    /// Localhost is always usable. Pollers gate every cycle on this and
    /// skip while the host is down/offline/sleeping — no blind retries
    /// hammering an unreachable remote.
    public func hostUsable(_ host: HostConfig?) -> Bool {
        guard let host, !host.isLocal else { return true }
        // Read the flag directly as well as the published health: a pause
        // toggled in Settings must take effect on the spot, not on the
        // supervisor's next tick.
        guard !host.paused else { return false }
        return ConnectionPairRegistry.shared.health(for: host).state.isUsable
    }

    /// Whether the host owning `hostID` is paused by the user.
    public func hostIsPaused(_ hostID: UUID) -> Bool {
        host(for: hostID)?.paused ?? false
    }

    /// Pause / un-pause a host. Everything else about it is preserved —
    /// this only decides whether Onyx may open connections to it.
    public func setHostPaused(_ hostID: UUID, paused: Bool) {
        guard var host = host(for: hostID), host.paused != paused else { return }
        host.paused = paused
        updateHost(host)
    }

    /// Claim a utility SSH channel for `host`. Returns a release closure
    /// (call it in a defer), or nil when this cycle must be skipped: the
    /// identical poll is still in flight (slow network — the old code
    /// piled these up 2-3×) or the host is at its concurrent-channel cap.
    public func acquireUtilityChannel(_ label: String, host: HostConfig?) -> (() -> Void)? {
        guard let host, !host.isLocal else { return {} }
        // Backstop for any caller that forgot the hostUsable gate: a paused
        // host must never see an ssh invocation.
        guard !host.paused else { return nil }
        let budget = ConnectionPairRegistry.shared.pair(for: host).channelBudget
        guard budget.acquire(label) else { return nil }
        return { budget.release(label) }
    }

    /// SSH args for short-lived utility commands (stats, enumeration, file browser).
    /// Uses mux for efficiency — these are ephemeral and can retry if mux dies.
    func sshBaseArgs(for host: HostConfig, batchMode: Bool = true, connectTimeout: Int = 5) -> [String] {
        var args = sshMuxArgs(for: host)
        if batchMode {
            args.append("-o"); args.append("BatchMode=yes")
        }
        args.append("-o"); args.append("ConnectTimeout=\(connectTimeout)")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if host.ssh.port != 22 {
            args.append("-p"); args.append("\(host.ssh.port)")
        }
        if !host.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(host.ssh.identityFile)
        }
        return args
    }

    /// SSH args for long-lived interactive sessions (terminal, docker tmux,
    /// logs, LSP). Rides the host's connection pair as a mux channel —
    /// `ControlMaster=no` means a terminal can NEVER open its own TCP
    /// connection. The pair's active master owns the connection and its
    /// keepalives; when it dies, every channel EOFs together and the
    /// terminals instantly reattach through the promoted standby (tmux
    /// preserves all session state). This is the hard two-connections-
    /// per-host cap.
    func sshSessionArgs(for host: HostConfig, connectTimeout: Int = 10) -> [String] {
        var args: [String] = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(sshControlPath(for: host))",
        ]
        args.append("-o"); args.append("ConnectTimeout=\(connectTimeout)")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if host.ssh.port != 22 {
            args.append("-p"); args.append("\(host.ssh.port)")
        }
        if !host.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(host.ssh.identityFile)
        }
        return args
    }

    /// SSH base args for SCP (uses -P instead of -p for port, uses mux)
    func scpBaseArgs(for host: HostConfig) -> [String] {
        let controlPath = sshControlPath(for: host)
        var args: [String] = [
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if host.ssh.port != 22 {
            args.append("-P"); args.append("\(host.ssh.port)")
        }
        if !host.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(host.ssh.identityFile)
        }
        return args
    }

    /// User@host string for SSH commands
    func sshUserHost(for host: HostConfig) -> String {
        host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
    }

    /// Capture a full diagnostic of the host's SSH mux state. Unlike
    /// `sshMuxAlive` (which throws away every signal except success/fail)
    /// this version preserves the actual ssh command, the captured
    /// stderr, the socket-file stat, and the exit code — everything the
    /// monitor overlay needs to render an actionable "why isn't this
    /// working?" view. Also logs the result to the `ssh` os.Logger
    /// category so it shows up in Console for forensics later.
    public func diagnoseSSHMux(for host: HostConfig) -> SSHMuxDiagnostic {
        OnyxLog.ssh.info("mux check started: host=\(host.label, privacy: .public)")
        let controlPath = sshControlPath(for: host)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: controlPath)
        let age: TimeInterval? = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: controlPath),
                  let m = attrs[.modificationDate] as? Date else { return nil }
            return Date().timeIntervalSince(m)
        }()

        // Localhost: short-circuit. Mux is irrelevant but the section
        // still asks for diagnostics for consistency.
        guard !host.isLocal else {
            return SSHMuxDiagnostic(
                muxAlive: true,
                controlPath: "(local — no mux needed)",
                socketExists: false,
                socketAgeSeconds: nil,
                checkCommand: "(local)",
                checkOutput: "Localhost — no SSH mux required.",
                checkExitCode: 0,
                host: host,
                timestamp: Date()
            )
        }

        let args = [
            "-o", "ControlPath=\(controlPath)",
            "-O", "check",
            sshUserHost(for: host)
        ]
        let command = "/usr/bin/ssh " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
                                            .joined(separator: " ")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        var output = ""
        var exitCode: Int32?
        do {
            try process.run()
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 3)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()
            process.waitUntilExit()
            killTimer.cancel()
            exitCode = process.terminationStatus
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {
            output = "ssh failed to launch: \(error.localizedDescription)"
        }

        let diag = SSHMuxDiagnostic(
            muxAlive: exitCode == 0,
            controlPath: controlPath,
            socketExists: exists,
            socketAgeSeconds: age,
            checkCommand: command,
            checkOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
            checkExitCode: exitCode,
            host: host,
            timestamp: Date()
        )
        if diag.muxAlive {
            OnyxLog.ssh.info("mux alive: host=\(host.label, privacy: .public)")
        } else {
            OnyxLog.ssh.error("""
                mux DOWN: host=\(host.label, privacy: .public) \
                exit=\(exitCode ?? -1, privacy: .public) \
                socketExists=\(exists, privacy: .public) \
                summary=\(diag.summary, privacy: .public) \
                output=\(diag.checkOutput, privacy: .public)
                """)
        }
        return diag
    }

    /// Run a bare `ssh -v -o BatchMode=yes -o ConnectTimeout=5 user@host
    /// true` and capture the output. Useful for sanity-checking that
    /// keys / network / sshd are all working, independent of the mux.
    public func testSSHConnection(for host: HostConfig) -> SSHConnectTest {
        guard !host.isLocal else {
            return SSHConnectTest(host: host, success: true,
                                  command: "(local)",
                                  output: "Localhost — no SSH connection required.",
                                  exitCode: 0, timestamp: Date())
        }

        // Built from scratch — no mux options, just basic + verbose. This
        // is intentionally an apples-to-apples reproduction of "what
        // happens if I run ssh -v from my terminal" so the user can
        // correlate Onyx's failure mode with their shell behavior.
        var args: [String] = ["-v",
                              "-o", "BatchMode=yes",
                              "-o", "ConnectTimeout=5",
                              "-o", "StrictHostKeyChecking=accept-new"]
        if host.ssh.port != 22 {
            args.append("-p"); args.append("\(host.ssh.port)")
        }
        if !host.ssh.identityFile.isEmpty {
            args.append("-i"); args.append(host.ssh.identityFile)
        }
        args.append(sshUserHost(for: host))
        args.append("true")

        let command = "/usr/bin/ssh " + args.joined(separator: " ")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        var output = ""
        var exitCode: Int32?
        do {
            try process.run()
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 12)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()
            process.waitUntilExit()
            killTimer.cancel()
            exitCode = process.terminationStatus
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
        } catch {
            output = "ssh failed to launch: \(error.localizedDescription)"
        }

        let result = SSHConnectTest(
            host: host,
            success: exitCode == 0,
            command: command,
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: exitCode,
            timestamp: Date()
        )
        OnyxLog.ssh.info("""
            connect test: host=\(host.label, privacy: .public) \
            success=\(result.success, privacy: .public) \
            exit=\(exitCode ?? -1, privacy: .public)
            """)
        return result
    }

    /// Tear down both pair slots for a host. The next supervisor
    /// tick re-establishes them from scratch — typically within ≈4s.
    public func resetSSHMux(for host: HostConfig) {
        OnyxLog.ssh.notice("user reset: host=\(host.label, privacy: .public)")
        ConnectionPairRegistry.shared.reset(for: host)
    }

    /// Check if the SSH mux master is alive for a host. Delegates to
    /// the pair registry for an instant cached answer — the supervisor
    /// polls every 2s anyway, so callers don't need to pay for a fresh
    /// `ssh -O check` themselves.
    ///
    /// Returns true for localhost (no mux needed) and for any host
    /// whose active slot is confirmed alive.
    public func sshMuxAlive(for host: HostConfig) -> Bool {
        guard !host.isLocal else { return true }
        return ConnectionPairRegistry.shared.isMuxAlive(for: host)
    }

    /// Tear down the SSH mux master(s) for a host — *definitively*.
    /// `ssh -O exit` first (clean), then SIGKILL the owning process
    /// via lsof if the clean exit didn't kill it, then remove the
    /// socket file. Covers both pair slots and any legacy single-slot
    /// path. Bounded; never hangs.
    public func sshMuxStop(for host: HostConfig) {
        guard !host.isLocal else { return }
        ConnectionPairRegistry.shared.removePair(for: host.id)
        // Belt-and-braces: sweep both slot paths directly in case the
        // pair was never created (legacy sockets from a prior run).
        let userHost = sshUserHost(for: host)
        let paths = Set([
            ConnectionPair.slotPath(for: host.id, slot: 0),
            ConnectionPair.slotPath(for: host.id, slot: 1),
        ])
        for path in paths {
            SSHProcess.killMaster(at: path, userHost: userHost)
        }
    }

    // MARK: - Command Builders

    /// Extra PATH entries so tmux/docker are found even when login profile doesn't set it.
    /// Uses export so it works before compound commands (while/if/for) in all shells.
    ///
    /// Static: it is a constant of the protocol with remote hosts, not
    /// state of a window — and an extension can't hold stored properties
    /// anyway.
    static let extraPathValue = "PATH=$PATH:/opt/homebrew/bin:/usr/local/bin:/snap/bin"
    var extraPath: String { Self.extraPathValue }

    /// Run a shell command on a host and return (executable, args).
    ///
    /// **Use only for fire-and-forget side-effect commands** (e.g.
    /// hook-setup mkdir/chmod, port cleanup). For ANY data-reading
    /// SSH command — anything whose output you parse — use
    /// `remoteScript(_:host:)` instead. This variant uses `$SHELL -lc`
    /// which fails silently on remotes that have `set -n` in their
    /// login profile (the script source comes back instead of running).
    /// See CLAUDE.md "Remote command execution".
    public func remoteCommand(_ script: String, host: HostConfig? = nil) -> (String, [String]) {
        let h = host ?? activeHost ?? .localhost
        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "export \(extraPath); \(script)"])
        }

        var args = sshBaseArgs(for: h)
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc 'export \(extraPath); \(script)'")
        return ("/usr/bin/ssh", args)
    }

    /// Run a shell script on a host, returning (cmd, args, stdin?).
    ///
    /// The script is wrapped by `RemoteScript.wrap` (PATH setup, defensive
    /// `set +vx`, and an execution-proof marker so callers can detect
    /// noexec hosts). For local hosts the wrapped script goes through
    /// `$SHELL -c`. For remote hosts the script is fed via stdin to an
    /// interactive ssh session (`ssh -tt` with no command argument), which
    /// bypasses every common noexec trap on hostile remotes.
    ///
    /// **The caller MUST feed `stdin` to the spawned process when non-nil**
    /// (always non-nil for remote hosts). After execution, run the
    /// captured output through `RemoteScript.cleanedOutput` before parsing
    /// and check `RemoteScript.executionVerified` to detect noexec.
    ///
    /// Use this for any read-data SSH command. For interactive sessions
    /// (tmux, docker exec -it) use `sshCommand` / `dockerTmuxCommand`
    /// directly — those are safe by virtue of being interactive.
    public func remoteScript(_ script: String, host: HostConfig? = nil) -> (cmd: String, args: [String], stdin: String?) {
        remoteScript(script, host: host, allocateTTY: true)
    }

    /// The same invocation without a terminal on the far end.
    ///
    /// `-tt` exists to defeat noexec shells (see RemoteScript's header),
    /// and it costs us dearly: a terminal has a ~1KB input queue, drops
    /// what it can't hold, and — as observed on a real host — can hand the
    /// shell a MANGLED tail, which then reports "command not found" and
    /// takes the session down with it (exit 127, no completion marker, no
    /// error anyone could act on).
    ///
    /// Without a tty, stdin is an ordinary pipe: no queue limit, no line
    /// discipline, no echo, nothing to corrupt. The trade is that the
    /// remote shell is then NON-interactive, which is exactly the state a
    /// noexec profile can poison — so callers should try this first and
    /// fall back to the tty form when the completion marker doesn't come
    /// back. `FileBrowserManager.runScriptWithFallback` does that.
    public func remoteScriptNoTTY(_ script: String, host: HostConfig? = nil) -> (cmd: String, args: [String], stdin: String?) {
        remoteScript(script, host: host, allocateTTY: false)
    }

    private func remoteScript(_ script: String, host: HostConfig?,
                              allocateTTY: Bool) -> (cmd: String, args: [String], stdin: String?) {
        let h = host ?? activeHost ?? .localhost
        let wrapped = RemoteScript.wrap(script)

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-c", wrapped], nil)
        }

        var args = sshBaseArgs(for: h)
        if allocateTTY {
            args.append("-tt")
        } else {
            // -T: explicitly no terminal. The script arrives over a pipe,
            // intact, at any size.
            args.append("-T")
        }
        args.append(sshUserHost(for: h))
        guard allocateTTY else {
            // No tty: no echo to suppress, and the shell exits at EOF.
            return ("/usr/bin/ssh", args, wrapped + "\n")
        }
        // NB: `-tt` puts a TERMINAL on the far end, and a terminal cannot
        // be written to at full speed — see RemoteExec's paced stdin
        // writer, which is what actually gets this script delivered
        // intact. Keeping lines short (see statsCommand) matters for the
        // same reason.
        let stdinScript = """
        stty -echo 2>/dev/null
        \(wrapped)
        exit

        """
        return ("/usr/bin/ssh", args, stdinScript)
    }

    /// Sanitize a session name for safe shell interpolation
    func sanitizedSession(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    /// Sanitize a container name for safe shell interpolation
    func sanitizedContainer(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    /// MCP `-R` reverse-forwarding flags for the pair's MASTER connection.
    /// Port forwardings belong to the master, not to channel clients — a
    /// mux client can't reliably request `-R` at channel-open time. The
    /// pair registry appends these when establishing each master, so the
    /// forwarding is available to every channel (terminals included).
    /// `ExitOnForwardFailure=no` keeps a busy port from failing the master.
    func mcpMasterForwardingFlags() -> [String] {
        guard let localPort = mcpServer?.tcpPort else { return [] }
        let remotePort = MCPSocketServer.defaultRemotePort
        return ["-o", "ExitOnForwardFailure=no", "-R", "\(remotePort):127.0.0.1:\(localPort)"]
    }

    /// Env export prefix telling remote shells where the MCP forwarding
    /// lives (the forwarding itself is established by the pair's master).
    private func mcpForwardingArgs() -> (sshFlags: [String], envExport: String) {
        guard mcpServer?.tcpPort != nil else { return ([], "") }
        let remotePort = MCPSocketServer.defaultRemotePort
        return (
            [],
            "export ONYX_MCP_PORT=\(remotePort); tmux set-environment ONYX_MCP_PORT \(remotePort) 2>/dev/null; "
        )
    }

    /// Kill stale MCP port listeners on a remote host before connecting.
    /// Call this before establishing an SSH session with `-R` forwarding.
    /// Fire-and-forget cleanup of stale MCP port listeners on a remote host.
    /// Runs asynchronously to avoid blocking the main thread (SSH may hang if
    /// the network is asleep, e.g. when the screen saver activates).
    public func cleanupRemoteMCPPort(host h: HostConfig) {
        guard !h.isLocal, mcpServer?.tcpPort != nil else { return }
        let remotePort = MCPSocketServer.defaultRemotePort
        let (cmd, args) = remoteCommand("lsof -ti tcp:\(remotePort) 2>/dev/null | xargs kill 2>/dev/null", host: h)
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 5)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()

            try? process.run()
            process.waitUntilExit()
            killTimer.cancel()
        }
    }

    /// Build the command for a session based on its source
    public func commandForSession(_ session: TmuxSession) -> (String, [String]) {
        let h = host(for: session.source.hostID) ?? .localhost
        switch session.source {
        case .host:
            return sshCommand(host: h, sessionName: session.name)
        case .docker(_, let containerName):
            return dockerTmuxCommand(host: h, container: containerName, sessionName: session.name)
        case .dockerLogs(_, let containerName):
            return dockerLogsCommand(host: h, container: containerName)
        case .dockerTop(_, let containerName):
            return dockerTopCommand(host: h, container: containerName)
        case .browser:
            // Browser sessions don't use SSH commands
            return ("/usr/bin/true", [])
        }
    }

    /// Build the command to stream docker container logs (read-only)
    public func dockerLogsCommand(host h: HostConfig, container: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let dockerCmd = "docker logs -f --tail 1000 \(safeContainer)"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "export \(extraPath); \(dockerCmd)"])
        }

        var args = sshSessionArgs(for: h)
        args.append("-t")
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc 'export \(extraPath); \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to show docker container processes (refreshes every 2s)
    public func dockerTopCommand(host h: HostConfig, container: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        // Wrap in a function so PATH assignment + while loop works in all shells (zsh
        // doesn't allow inline VAR=value before compound commands like while/if/for)
        let dockerCmd = "export \(extraPath); while true; do clear; date; echo; docker top \(safeContainer) -eo pid,user,%cpu,%mem,etime,comm 2>&1; sleep 2; done"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", dockerCmd])
        }

        var args = sshSessionArgs(for: h)
        args.append("-t")
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc '\(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command for a host tmux session
    public func sshCommand(host h: HostConfig, sessionName: String) -> (String, [String]) {
        let sess = sanitizedSession(sessionName)

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "export \(extraPath); tmux new-session -A -s \(sess)"])
        }

        var args = sshSessionArgs(for: h)
        // MCP remote port forwarding — allows remote agents to talk back to Onyx
        let mcpArgs = mcpForwardingArgs()
        args.append(contentsOf: mcpArgs.sshFlags)
        args.append("-t")
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc '\(mcpArgs.envExport)export \(extraPath); tmux new-session -A -s \(sess)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to attach to a tmux session inside a docker container
    public func dockerTmuxCommand(host h: HostConfig, container: String, sessionName: String) -> (String, [String]) {
        let safeContainer = sanitizedContainer(container)
        let safeSess = sanitizedSession(sessionName)
        let dockerCmd = "docker exec -it \(safeContainer) tmux new-session -A -s \(safeSess)"

        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "export \(extraPath); \(dockerCmd)"])
        }

        var args = sshSessionArgs(for: h)
        // MCP remote port forwarding
        let mcpArgs = mcpForwardingArgs()
        args.append(contentsOf: mcpArgs.sshFlags)
        args.append("-t")
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc '\(mcpArgs.envExport)export \(extraPath); \(dockerCmd)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command to launch a language server (jdtls) over a CLEAN byte
    /// pipe for LSP `Content-Length` framing.
    ///
    /// **This is deliberately NOT like `sshCommand`/`dockerTmuxCommand`.** LSP
    /// is a raw framed-byte stream; a pseudo-TTY would echo our stdin and
    /// translate newlines and corrupt the framing — so there is **no `-t`**,
    /// and no MCP port forwarding. Safe from the noexec trap because the server
    /// is a real `exec`, not a shell command the outer shell must interpret.
    /// See docs/lsp-code-navigation-plan.md and the jdtls spike.
    ///
    /// `launch` is the server invocation, e.g. `~/.onyx/jdtls/bin/jdtls -data <dir>`.
    public func remoteLSPCommand(host h: HostConfig, launch: String) -> (String, [String]) {
        if h.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return (shell, ["-lc", "export \(extraPath); \(launch)"])
        }

        var args = sshSessionArgs(for: h)   // long-lived mux channel on the pair
        // NO "-t": an LSP stream must stay a clean byte pipe.
        args.append(sshUserHost(for: h))
        args.append("exec $SHELL -lc 'export \(extraPath); \(launch)'")
        return ("/usr/bin/ssh", args)
    }

    /// Build the command + args to run a one-off stats collection.
    /// When `stdin` is non-nil the caller must feed it to the spawned
    /// process's standard input. We use this for remote hosts to drive
    /// an interactive SSH shell — see the comment on the SSH branch.
    public func statsCommand(host h: HostConfig? = nil) -> (cmd: String, args: [String], stdin: String?) {
        let host = h ?? activeHost ?? .localhost
        // The DOCKER section was added for the screensaver's per-container
        // moon ring. MonitorManager.parse silently ignores unknown
        // sections, so this change is invisible to the existing monitor
        // overlay; only CPUFleetPoller reads the docker output.
        // KEEP THIS SCRIPT SMALL. It is fed to an interactive shell over a
        // PTY (`-tt`), and a terminal's input queue is ~1KB in total on
        // macOS — not per line, in total. Overflow it and the remainder is
        // discarded by the kernel: the shell waits for the rest of a line
        // that never comes, emits nothing but its login banner, and the
        // poll dies at the watchdog with no error to show for it.
        //
        // Pacing (RemoteExec.writePaced) is necessary but NOT sufficient.
        // Measured on a real failing host: unpaced, a 2.2KB script
        // produced nothing at all; paced, the front of it ran (a CPU
        // reading arrived) and the tail was still lost — no MEM section,
        // and no `exit`, so the session hung until the watchdog. Keep
        // both: pace the writes AND keep the payload small.
        //
        // This script was 736 bytes and worked on every host for months.
        // Adding AMD GPU + NPU probing took it to 2.4KB and killed stats
        // on every Mac — which is why that probing now lives in
        // `acceleratorCommand`, sent only to hosts that can answer it.
        // AppStateTests holds the size line; treat it as a hard budget,
        // not a guideline.
        let statsScript = """
        echo "---OS---"; uname -s
        echo "---UPTIME---"; uptime
        echo "---CPU---"; CPU_OUT=$(top -bn1 2>/dev/null | head -5)
        if [ -n "$CPU_OUT" ]; then echo "$CPU_OUT"; else top -l1 -s0 2>/dev/null | head -10; fi
        echo "---MEM---"; MEM_OUT=$(free -m 2>/dev/null)
        if [ -n "$MEM_OUT" ]; then echo "$MEM_OUT"; else vm_stat 2>/dev/null; fi
        echo "---GPU---"; G=$(timeout 5 nvidia-smi --query-gpu=utilization.gpu,utilization.memory,temperature.gpu,name --format=csv,noheader 2>/dev/null)
        [ -n "$G" ] || G=$(ioreg -r -d 1 -c IOAccelerator 2>/dev/null | grep -o 'Utilization %"=[0-9]*' | head -1 | cut -d= -f2 | sed 's/^/AGX,/')
        [ -n "$G" ] && echo "$G" || echo "N/A"
        echo "---DOCKER---"; T=""; command -v timeout >/dev/null 2>&1 && T="timeout 6"
        $T docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}" 2>/dev/null || true
        """
        return remoteScript(statsScript, host: host)
    }

    /// Which accelerator to ask about. They're separate calls because a
    /// remote terminal will only swallow about 1KB in one go, and the two
    /// probes together don't fit — see `statsCommand`'s size note.
    public enum AcceleratorProbe {
        case amdGPU
        case npu
    }

    /// Accelerator probing (AMD GPU via amdgpu sysfs, XDNA NPU via the
    /// accel class) as SEPARATE, smaller calls off the hot path.
    ///
    /// They ride their own channel on their own slower cadence, and are
    /// only ever sent to hosts that reported Linux — a Mac can't answer a
    /// line of this, so spending the stats script's tiny size budget on it
    /// there bought nothing and cost every Mac its stats.
    public func acceleratorCommand(_ probe: AcceleratorProbe,
                                   host h: HostConfig? = nil) -> (cmd: String, args: [String], stdin: String?) {
        let host = h ?? activeHost ?? .localhost
        let script: String
        switch probe {
        case .amdGPU:
            script = """
            D=/sys/class/drm; G=""
            for c in $(ls $D 2>/dev/null); do p=$D/$c/device; B=$(cat $p/gpu_busy_percent 2>/dev/null); [ "$B" -ge 0 ] 2>/dev/null || continue; U=$(cat $p/mem_info_vram_used 2>/dev/null); T=$(cat $p/mem_info_vram_total 2>/dev/null); M=N/A; [ "$T" -gt 0 ] 2>/dev/null && M=$(( U * 100 / T )); K=N/A; for w in $(ls $p/hwmon 2>/dev/null); do X=$(cat $p/hwmon/$w/temp1_input 2>/dev/null); [ "$X" -ge 0 ] 2>/dev/null && K=$(( X / 1000 )) && break; done; G="$B %, $M %, $K, AMD GPU"; break; done
            echo "---GPU---"; [ -n "$G" ] && echo "$G" || echo "N/A"
            """
        case .npu:
            script = """
            E=/sys/class/accel; P=""
            for n in $(ls $E 2>/dev/null); do a=$E/$n/device; N=$(cat $a/vbnv 2>/dev/null); [ -n "$N" ] || N=NPU; C=$(cat $a/power/control 2>/dev/null); S=$(cat $a/power/runtime_status 2>/dev/null); [ "$C" = on ] && S=unknown; [ -n "$S" ] || S=unknown; F=$(cat $a/fw_version 2>/dev/null); A=$(cat $a/power/runtime_active_time 2>/dev/null); [ "$A" -ge 0 ] 2>/dev/null || A=; P="$N|$S|$F|$A"; break; done
            echo "---NPU---"; [ -n "$P" ] && echo "$P" || echo "N/A"
            """
        }
        return remoteScript(script, host: host)
    }

    /// Build a shell command that generates a key (if needed) and runs ssh-copy-id
    public func keySetupCommand(host h: HostConfig) -> (String, [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let userHost = h.ssh.user.isEmpty ? h.ssh.host : "\(h.ssh.user)@\(h.ssh.host)"
        var portFlag = ""
        if h.ssh.port != 22 {
            portFlag = "-p \(h.ssh.port) "
        }
        var identityFlag = ""
        var keyPath = "~/.ssh/id_ed25519"
        if !h.ssh.identityFile.isEmpty {
            keyPath = h.ssh.identityFile
            identityFlag = "-i \(h.ssh.identityFile) "
        }

        let sessName = sanitizedSession(activeSession?.name ?? h.ssh.tmuxSession)

        let script = """
        echo ""; \
        echo "╔══════════════════════════════════════════╗"; \
        echo "║        ONYX SSH KEY SETUP                ║"; \
        echo "╚══════════════════════════════════════════╝"; \
        echo ""; \
        KEY="\(keyPath)"; \
        KEY=$(eval echo "$KEY"); \
        if [ ! -f "$KEY" ]; then \
            echo "→ No SSH key found at $KEY"; \
            echo "→ Generating a new ed25519 key..."; \
            echo ""; \
            ssh-keygen -t ed25519 -f "$KEY" -N "" || exit 1; \
            echo ""; \
            echo "✓ Key generated."; \
        else \
            echo "✓ Found existing key: $KEY"; \
        fi; \
        echo ""; \
        echo "→ Installing key on \(userHost)..."; \
        echo "  You will be asked for your password ONE TIME."; \
        echo ""; \
        ssh-copy-id \(identityFlag)\(portFlag)\(userHost); \
        if [ $? -eq 0 ]; then \
            echo ""; \
            echo "✓ Key installed successfully!"; \
            echo "→ Connecting..."; \
            echo ""; \
            sleep 1; \
            exec ssh \(portFlag)\(identityFlag)-t -o StrictHostKeyChecking=accept-new \(userHost) \
                "exec \\$SHELL -lc '\(extraPath) tmux new-session -A -s \(sessName)'"; \
        else \
            echo ""; \
            echo "✗ Key installation failed."; \
            echo "  Check the password and try again."; \
            exit 1; \
        fi
        """
        return (shell, ["-lc", script])
    }
}
