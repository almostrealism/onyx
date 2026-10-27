//
// NIOTransport.swift
//
// Responsibility: RemoteTransport over in-process SSH — the same seam the
//                 Mac's ProcessTransport fills with ssh and scp processes,
//                 filled here with SwiftNIO SSH, so every manager written
//                 against the seam works on iOS unchanged.
// Scope: One per app. Holds one connection per host, sessions riding it
//        as channels (docs/ios-plan.md, phase 2).
// Threading: Blocking calls, bounded by their timeout; call them off the
//            main thread, as every caller of the seam already does.
//
// Behaves like the process transport down to its failure conventions —
// exit 255 and ssh's wording for a connection that failed, a missing file
// reported the way scp reports one — because callers tell those apart
// (SharedStateSync.classify) and must not have to know which transport
// answered.
//

import Foundation
import NIOCore
import NIOSSH
import OnyxCore

public final class NIOTransport: RemoteTransport {

    public let name = "built-in"

    /// The keys to offer a host, and why any the user has can't be.
    public typealias IdentityProvider = (HostConfig) -> (usable: [SSHIdentity], skipped: [String])

    /// What a host's name really means — on a Mac, `~/.ssh/config`
    /// (`ssh -G`): its HostName, User and Port. nil means "as written".
    public typealias HostResolver = (HostConfig) throws -> ResolvedHost?

    /// OpenSSH servers allow 10 sessions per connection (MaxSessions);
    /// stay under it, with room for a terminal or two.
    static let sessionsPerConnection = 8

    private let knownHosts: KnownHostsStore
    private let identities: IdentityProvider
    private let resolver: HostResolver?
    private let connectTimeout: TimeInterval

    private final class Pooled {
        let connection: SSHConnection
        let slots = DispatchSemaphore(value: NIOTransport.sessionsPerConnection)
        init(_ connection: SSHConnection) { self.connection = connection }
    }

    private let lock = NSLock()
    private var pool: [String: Pooled] = [:]
    /// One connect at a time per host, so a burst of callers shares one.
    private var connecting: [String: NSLock] = [:]

    public init(knownHosts: KnownHostsStore = .shared,
                connectTimeout: TimeInterval = 10,
                resolver: HostResolver? = nil,
                identities: @escaping IdentityProvider = NIOTransport.defaultIdentities) {
        self.knownHosts = knownHosts
        self.connectTimeout = connectTimeout
        self.resolver = resolver
        self.identities = identities
    }

    /// The Onyx key first, then (on a Mac) the user's own key files.
    public static func defaultIdentities(_ host: HostConfig) -> (usable: [SSHIdentity], skipped: [String]) {
        var usable: [SSHIdentity] = []
        if let onyx = OnyxKey.load() { usable.append(onyx) }
        #if os(macOS)
        let files = OpenSSHKeyFile.userKeys(for: host)
        return (usable + files.usable, files.skipped)
        #else
        return (usable, [])
        #endif
    }

    // MARK: - Connections

    func target(for host: HostConfig) throws -> SSHTarget {
        if let resolved = try resolver?(host) {
            let keys = identities(host)
            return SSHTarget(host: resolved.hostName, port: resolved.port, user: resolved.user,
                             identities: keys.usable, skippedKeys: keys.skipped)
        }
        var user = host.ssh.user.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            #if os(macOS)
            user = NSUserName()
            #else
            throw SSHConnectionError.noUser(host: host.ssh.host)
            #endif
        }
        let keys = identities(host)
        return SSHTarget(host: host.ssh.host.trimmingCharacters(in: .whitespaces), port: host.ssh.port,
                         user: user, identities: keys.usable, skippedKeys: keys.skipped)
    }

    /// The host's connection, made if there isn't a live one.
    func connection(for host: HostConfig) throws -> SSHConnection {
        try pooled(for: try target(for: host)).connection
    }

    private func pooled(for target: SSHTarget) throws -> Pooled {
        let key = target.poolKey
        lock.lock()
        if let live = pool[key], live.connection.isActive {
            lock.unlock()
            return live
        }
        let gate = connecting[key] ?? NSLock()
        connecting[key] = gate
        lock.unlock()

        gate.lock()
        defer { gate.unlock() }
        // Someone else may have connected while we waited.
        lock.lock()
        if let live = pool[key], live.connection.isActive {
            lock.unlock()
            return live
        }
        lock.unlock()

        let connection = try SSHConnection.connect(target, knownHosts: knownHosts, timeout: connectTimeout)
        let fresh = Pooled(connection)
        lock.lock()
        pool[key] = fresh
        lock.unlock()
        connection.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.pool[key] === fresh { self.pool[key] = nil }
            self.lock.unlock()
        }
        keepAlive(connection)
        DiagnosticLog.shared.record("ssh", "built-in: connected to \(target.poolKey)")
        return fresh
    }

    /// How often an idle connection is checked, and how long it has to
    /// answer. A connection the network dropped silently (a laptop that
    /// slept, a phone that changed networks) is found and closed here, so
    /// the next call reconnects instead of waiting out its own timeout.
    static let keepaliveInterval: TimeInterval = 30
    static let keepaliveTimeout: TimeInterval = 10

    private func keepAlive(_ connection: SSHConnection) {
        let loop = connection.channel.eventLoop
        let interval = TimeAmount.milliseconds(Int64(Self.keepaliveInterval * 1000))
        let task = loop.scheduleRepeatedAsyncTask(initialDelay: interval, delay: interval) { task in
            guard connection.isActive else {
                task.cancel()
                return loop.makeSucceededVoidFuture()
            }
            return connection.ping(timeout: Self.keepaliveTimeout).map { alive in
                if !alive {
                    DiagnosticLog.shared.record("ssh", "built-in: \(connection.target.poolKey) stopped answering")
                    connection.close()
                }
            }
        }
        connection.closeFuture.whenComplete { _ in task.cancel() }
    }

    /// Drop a host's connection (its next call reconnects).
    public func disconnect(_ host: HostConfig) {
        guard let target = try? target(for: host) else { return }
        lock.lock()
        let dropped = pool.removeValue(forKey: target.poolKey)
        lock.unlock()
        dropped?.connection.close()
    }

    public func disconnectAll() {
        lock.lock()
        let all = pool.values
        pool.removeAll()
        lock.unlock()
        all.forEach { $0.connection.close() }
    }

    /// A session slot on a connection, given back exactly once.
    final class Slot {
        private let semaphore: DispatchSemaphore
        private let lock = NSLock()
        private var held = true
        /// Set by a body that keeps the slot past its return (a streaming
        /// job holds it until the session ends).
        var kept = false

        init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }

        func release() {
            lock.lock()
            let wasHeld = held
            held = false
            lock.unlock()
            if wasHeld { semaphore.signal() }
        }
    }

    /// Run `body` with a session slot on the host's connection. A
    /// connection found dead when the channel opens is replaced once — a
    /// phone back from the background holds sockets the network dropped.
    private func withConnection<T>(_ host: HostConfig, timeout: TimeInterval,
                                   _ body: (SSHConnection, Slot) throws -> T) throws -> T {
        let target = try target(for: host)
        var attempt = 0
        while true {
            let pooled = try pooled(for: target)
            guard pooled.slots.wait(timeout: .now() + timeout) == .success else {
                throw SSHConnectionError.timedOut(host: target.host)
            }
            let slot = Slot(pooled.slots)
            defer { if !slot.kept { slot.release() } }
            do {
                return try body(pooled.connection, slot)
            } catch where attempt == 0 && !pooled.connection.isActive {
                slot.kept = false
                attempt += 1
                lock.lock()
                if pool[target.poolKey] === pooled { pool[target.poolKey] = nil }
                lock.unlock()
                pooled.connection.close()
                continue
            }
        }
    }

    /// A connection for a terminal. Terminals don't take a session slot:
    /// they live for hours, and a few open terminals would starve every
    /// short call of the cap. They count against the server's MaxSessions
    /// all the same, which is why the cap leaves room for them.
    func withTerminalConnection<T>(_ host: HostConfig, _ body: (SSHConnection) throws -> T) throws -> T {
        let target = try target(for: host)
        let first = try pooled(for: target)
        do {
            return try body(first.connection)
        } catch where !first.connection.isActive {
            lock.lock()
            if pool[target.poolKey] === first { pool[target.poolKey] = nil }
            lock.unlock()
            return try body(try pooled(for: target).connection)
        }
    }

    // MARK: - Reverse forwards

    /// Have `host` listen on `remotePort` and send its connections to
    /// `localPort` on this device (`ssh -R`). Returns the port bound. The
    /// forward lasts as long as the host's connection; call again after a
    /// reconnect (`isConnected` tells).
    public func forwardRemotePort(_ remotePort: Int, on host: HostConfig, toLocalPort localPort: Int,
                                  timeout: TimeInterval = 10) throws -> Int {
        try withTerminalConnection(host) { connection in
            try connection.forwardRemotePort(remotePort, port: localPort)
                .waitBounded(timeout, host: connection.target.host)
        }
    }

    /// Whether there's a live connection to `host` right now.
    public func isConnected(_ host: HostConfig) -> Bool {
        guard let key = try? target(for: host).poolKey else { return false }
        lock.lock(); defer { lock.unlock() }
        return pool[key]?.connection.isActive == true
    }

    // MARK: - RemoteTransport

    /// How an invocation is put on the wire: the same text ProcessTransport
    /// sends (RemoteWire), so a host can't tell the transports apart.
    static func session(for invocation: RemoteInvocation) -> (SSHSessionRequest, SSHTerminalSize?, SSHStdin) {
        switch invocation {
        case .command(let command):
            return (.exec(RemoteWire.execCommand(command)), nil, .piped(Data()))
        case .script(let script, terminal: false):
            return (.shell, nil, .piped(Data(RemoteWire.pipeStdin(script).utf8)))
        case .script(let script, terminal: true):
            return (.shell, SSHTerminalSize(),
                    .paced(Data(RemoteWire.terminalStdin(script).utf8),
                           chunk: RemoteWire.terminalChunk, pause: RemoteWire.terminalPause))
        }
    }

    public func execute(_ invocation: RemoteInvocation, on host: HostConfig,
                        timeout: TimeInterval, label: String) -> RemoteOutput {
        if Self.isThisDevice(host) { return Self.noLocal }
        let started = Date()
        let stdout = OutputCollector()
        let stderr = OutputCollector()
        do {
            return try withConnection(host, timeout: timeout) { connection, _ in
                let (request, terminal, stdin) = Self.session(for: invocation)
                let session = try connection.startSession(
                    request, terminal: terminal, stdin: stdin,
                    onStdout: { stdout.append($0) }, onStderr: { stderr.append($0) })
                    .waitBounded(timeout, host: connection.target.host)
                let remaining = max(0.1, timeout - Date().timeIntervalSince(started))
                do {
                    let exit = try session.exitStatus.waitBounded(remaining, host: connection.target.host)
                    return RemoteOutput(exit: exit, stdout: stdout.text, stderr: stderr.text.trimmed,
                                        timedOut: false)
                } catch {
                    session.terminate()
                    return RemoteOutput(exit: -1, stdout: stdout.text, stderr: stderr.text.trimmed,
                                        timedOut: true)
                }
            }
        } catch {
            return Self.output(for: error)
        }
    }

    @discardableResult
    public func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
                      label: String, onOutput: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) -> RemoteJob {
        let job = NIOJob()
        guard !Self.isThisDevice(host) else {
            job.attach(nil, onExit: onExit)
            DispatchQueue.global().async { job.finish(-1) }
            return job
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let lines = Utf8Lines()
            let (request, terminal, stdin) = Self.session(for: invocation)
            do {
                let (session, slot) = try withConnection(host, timeout: timeout) { connection, slot in
                    let session = try connection.startSession(
                        request, terminal: terminal, stdin: stdin,
                        onStdout: { buffer in
                            let text = lines.append(buffer)
                            if !text.isEmpty { onOutput(text) }
                        },
                        onStderr: { _ in })
                        .waitBounded(timeout, host: connection.target.host)
                    slot.kept = true   // until the session ends
                    return (session, slot)
                }
                let deadline = session.channel.eventLoop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
                    session.terminate()
                }
                session.exitStatus.whenComplete { result in
                    deadline.cancel()
                    slot.release()
                    let rest = lines.flush()
                    if !rest.isEmpty { onOutput(rest) }
                    job.finish((try? result.get()) ?? -1)
                }
                job.attach(session, onExit: onExit)
            } catch {
                job.attach(nil, onExit: onExit)
                job.finish(-1)
            }
        }
        return job
    }

    public func upload(_ localPath: String, to remotePath: String, on host: HostConfig,
                       recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        if Self.isThisDevice(host) { return Self.noLocal }
        return transfer(host, timeout: timeout) { sftp in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory) else {
                throw LocalFileError(path: localPath)
            }
            let local = URL(fileURLWithPath: localPath)
            // Like scp: onto an existing folder means into it.
            var destination = remotePath
            if let existing = try sftp.statIfPresent(remotePath), existing.isDirectory {
                destination = Self.join(remotePath, local.lastPathComponent)
            }
            if isDirectory.boolValue {
                guard recursive else { throw LocalFileError(path: localPath, reason: "not a regular file") }
                try Self.uploadFolder(local, to: destination, sftp: sftp)
            } else {
                try Self.uploadFile(local, to: destination, sftp: sftp)
            }
        }
    }

    public func download(_ remotePath: String, to localPath: String, from host: HostConfig,
                         recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        if Self.isThisDevice(host) { return Self.noLocal }
        return transfer(host, timeout: timeout) { sftp in
            let attributes = try sftp.stat(remotePath)
            var local = URL(fileURLWithPath: localPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory), isDirectory.boolValue {
                local.appendPathComponent((SFTPClient.wirePath(remotePath) as NSString).lastPathComponent)
            }
            if attributes.isDirectory {
                guard recursive else {
                    throw SFTPError(code: 4, message: "not a regular file", path: remotePath)
                }
                try Self.downloadFolder(remotePath, to: local, sftp: sftp)
            } else {
                try Self.downloadFile(remotePath, to: local, sftp: sftp)
            }
        }
    }

    // MARK: - Transfers

    private func transfer(_ host: HostConfig, timeout: TimeInterval,
                          _ body: @escaping (SFTPClient) throws -> Void) -> RemoteOutput {
        do {
            try withConnection(host, timeout: timeout) { connection, _ in
                let sftp = try SFTPClient.open(on: connection, timeout: timeout)
                defer { sftp.close() }
                try body(sftp)
            }
            return RemoteOutput(exit: 0, stdout: "", stderr: "", timedOut: false)
        } catch {
            return Self.output(for: error)
        }
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    private static func uploadFile(_ local: URL, to remote: String, sftp: SFTPClient) throws {
        let data: Data
        do { data = try Data(contentsOf: local) } catch { throw LocalFileError(path: local.path) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: local.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        let modified = attributes?[.modificationDate] as? Date
        try sftp.write(data, to: remote, permissions: mode, modificationTime: modified)
    }

    private static func uploadFolder(_ local: URL, to remote: String, sftp: SFTPClient) throws {
        if try sftp.statIfPresent(remote) == nil { try sftp.mkdir(remote) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []
        for name in names.sorted() {
            let child = local.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try uploadFolder(child, to: join(remote, name), sftp: sftp)
            } else {
                try uploadFile(child, to: join(remote, name), sftp: sftp)
            }
        }
    }

    private static func downloadFile(_ remote: String, to local: URL, sftp: SFTPClient) throws {
        let (data, attributes) = try sftp.read(remote)
        do {
            try data.write(to: local)
        } catch {
            throw LocalFileError(path: local.path, reason: "could not be written")
        }
        var set: [FileAttributeKey: Any] = [:]
        if let mode = attributes.permissions { set[.posixPermissions] = NSNumber(value: mode & 0o7777) }
        if let time = attributes.modificationTime { set[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(time)) }
        try? FileManager.default.setAttributes(set, ofItemAtPath: local.path)
    }

    private static func downloadFolder(_ remote: String, to local: URL, sftp: SFTPClient) throws {
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for entry in try sftp.list(remote) {
            let child = join(remote, entry.name)
            if entry.attributes.isDirectory {
                try downloadFolder(child, to: local.appendingPathComponent(entry.name), sftp: sftp)
            } else {
                try downloadFile(child, to: local.appendingPathComponent(entry.name), sftp: sftp)
            }
        }
    }

    // MARK: - Failures

    /// The process transport's conventions: 255 and ssh's words when the
    /// connection failed, 1 and scp's words when the file did.
    static func output(for error: Error) -> RemoteOutput {
        switch error {
        case let sftp as SFTPError:
            return RemoteOutput(exit: 1, stdout: "", stderr: sftp.description, timedOut: false)
        case let local as LocalFileError:
            return RemoteOutput(exit: 1, stdout: "", stderr: local.description, timedOut: false)
        case let ssh as SSHConnectionError:
            if case .timedOut = ssh {
                return RemoteOutput(exit: 255, stdout: "", stderr: ssh.description, timedOut: true)
            }
            return RemoteOutput(exit: 255, stdout: "", stderr: ssh.description, timedOut: false)
        default:
            return RemoteOutput(exit: 255, stdout: "", stderr: "ssh: \(error)", timedOut: false)
        }
    }

    /// The one host this client can't reach: "this device", with no
    /// address at all. A loopback address is a TCP connection like any
    /// other — and from an iOS simulator it is the Mac running it —
    /// unlike `HostConfig.isLocal`, which on the Mac means "run it here
    /// as a process", a decision for the process transport.
    static func isThisDevice(_ host: HostConfig) -> Bool {
        host.ssh.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let noLocal = RemoteOutput.failed("the built-in SSH client doesn't run commands on this device")
}

/// A host as OpenSSH would connect to it.
public struct ResolvedHost: Equatable {
    public let hostName: String
    public let port: Int
    public let user: String
    /// The key files OpenSSH would offer, in its order.
    public let identityFiles: [String]

    public init(hostName: String, port: Int, user: String, identityFiles: [String]) {
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFiles = identityFiles
    }
}

struct LocalFileError: Error, CustomStringConvertible {
    let path: String
    var reason = "No such file or directory"
    var description: String { "scp: \(path): \(reason)" }
}

/// A streaming session, cancellable before or after it has started.
/// `onExit` is called exactly once: with the status, or -1 for a job
/// cancelled or never started — at once on cancel, not when the server
/// gets round to closing.
final class NIOJob: RemoteJob {
    private let lock = NSLock()
    private var session: SSHSession?
    private var onExit: ((Int32) -> Void)?
    private var cancelled = false
    private var finished = false
    private var pendingStatus: Int32?

    func attach(_ session: SSHSession?, onExit: @escaping (Int32) -> Void) {
        lock.lock()
        self.session = session
        self.onExit = onExit
        let cancelledFirst = cancelled
        let early = pendingStatus
        lock.unlock()
        if cancelledFirst {
            session?.terminate()
            finish(-1)
        } else if let early {
            finish(early)
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard let callback = onExit else {
            // The session ended before attach ran; deliver it there.
            pendingStatus = pendingStatus ?? status
            lock.unlock()
            return
        }
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        callback(status)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let session = self.session
        let attached = onExit != nil
        lock.unlock()
        session?.terminate()
        if attached { finish(-1) }
    }
}

/// Bytes collected from the event loop, read once the run has ended.
final class OutputCollector {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ buffer: ByteBuffer) {
        var b = buffer
        guard let chunk = b.readBytes(length: b.readableBytes) else { return }
        lock.lock()
        bytes.append(contentsOf: chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Streamed bytes become text at line ends, so a character split across
/// two packets is never decoded in halves.
final class Utf8Lines {
    private var pending = Data()

    func append(_ buffer: ByteBuffer) -> String {
        var b = buffer
        guard let chunk = b.readBytes(length: b.readableBytes) else { return "" }
        pending.append(contentsOf: chunk)
        guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return "" }
        let ready = pending[pending.startIndex...last]
        pending = Data(pending[(last + 1)...])
        return String(decoding: ready, as: UTF8.self)
    }

    func flush() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
