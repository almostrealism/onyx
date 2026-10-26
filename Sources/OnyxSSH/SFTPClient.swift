//
// SFTPClient.swift
//
// Responsibility: Files to and from a host over the `sftp` subsystem
//                 (SFTP version 3, draft-ietf-secsh-filexfer-02 — what
//                 every OpenSSH server speaks). What `scp` does since
//                 OpenSSH 9.0, which is why the path rules match: no shell
//                 anywhere, paths absolute or relative to the remote home.
// Scope: One per transfer, on one session channel.
// Threading: Blocking calls, made off the event loop; the packets
//            themselves are handled on it.
//
// Our own rather than a library's (docs/ios-plan.md, phase 2): the
// handful of requests a transfer needs is a few hundred lines, and every
// SFTP library for NIO brings an SSH client of its own with it.
//

import Foundation
import NIOCore
import NIOSSH

public struct SFTPError: Error, Equatable, CustomStringConvertible {
    public let code: UInt32
    public let message: String
    public let path: String

    public static let noSuchFile: UInt32 = 2
    public static let permissionDenied: UInt32 = 3

    /// scp's wording, so `SharedStateSync.classify` reads it the same.
    public var description: String {
        switch code {
        case Self.noSuchFile: return "scp: \(path): No such file or directory"
        case Self.permissionDenied: return "scp: \(path): Permission denied"
        default: return "scp: \(path): \(message.isEmpty ? "failure" : message)"
        }
    }
}

/// The attributes the transfers use.
public struct SFTPAttributes: Equatable {
    public var size: UInt64?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, permissions: UInt32? = nil,
                accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    public var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }

    static let sizeFlag: UInt32 = 0x1, uidGidFlag: UInt32 = 0x2, permissionsFlag: UInt32 = 0x4,
               timesFlag: UInt32 = 0x8, extendedFlag: UInt32 = 0x8000_0000

    func encode(into w: inout SSHWireWriter) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.sizeFlag }
        if permissions != nil { flags |= Self.permissionsFlag }
        if accessTime != nil || modificationTime != nil { flags |= Self.timesFlag }
        w.uint32(flags)
        if let size { w.uint64(size) }
        if let permissions { w.uint32(permissions) }
        if flags & Self.timesFlag != 0 {
            w.uint32(accessTime ?? modificationTime ?? 0)
            w.uint32(modificationTime ?? accessTime ?? 0)
        }
    }

    static func decode(_ r: inout SSHWireReader) -> SFTPAttributes? {
        guard let flags = r.uint32() else { return nil }
        var a = SFTPAttributes()
        if flags & sizeFlag != 0 { a.size = r.uint64() }
        if flags & uidGidFlag != 0 { _ = r.uint32(); _ = r.uint32() }
        if flags & permissionsFlag != 0 { a.permissions = r.uint32() }
        if flags & timesFlag != 0 { a.accessTime = r.uint32(); a.modificationTime = r.uint32() }
        if flags & extendedFlag != 0, let count = r.uint32() {
            for _ in 0..<count { _ = r.data(); _ = r.data() }
        }
        return a
    }
}

/// Packet framing and request matching, on the event loop.
final class SFTPChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    struct Reply {
        let type: UInt8
        let body: Data
    }

    private var inbound = Data()
    /// Requests waiting for their reply, by id; the version reply has none.
    private var waiting: [UInt32: EventLoopPromise<Reply>] = [:]
    var versionPromise: EventLoopPromise<UInt32>?
    let started: EventLoopPromise<Void>

    init(loop: EventLoop) {
        started = loop.makePromise()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true))
            .whenFailure { [started] in started.fail($0) }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: started.succeed(())
        case is ChannelFailureEvent:
            started.fail(SSHConnectionError.rejected("subsystem request failed on channel 0 (sftp)"))
            context.close(promise: nil)
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func send(_ packet: Data, id: UInt32?, context: ChannelHandlerContext?, channel: Channel) -> EventLoopFuture<Reply>? {
        var promise: EventLoopPromise<Reply>?
        if let id {
            let p = channel.eventLoop.makePromise(of: Reply.self)
            waiting[id] = p
            promise = p
        }
        var buffer = channel.allocator.buffer(capacity: packet.count + 4)
        buffer.writeInteger(UInt32(packet.count))
        buffer.writeBytes(packet)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        return promise?.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data,
              let chunk = bytes.readBytes(length: bytes.readableBytes) else { return }
        inbound.append(contentsOf: chunk)
        while inbound.count >= 4 {
            let length = inbound.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard inbound.count >= 4 + length, length >= 1 else { break }
            let packet = inbound.subdata(in: inbound.startIndex + 4..<inbound.startIndex + 4 + length)
            inbound.removeFirst(4 + length)
            let type = packet[packet.startIndex]
            let body = packet.dropFirst()
            if type == SFTPClient.Packet.version {
                var r = SSHWireReader(Data(body))
                versionPromise?.succeed(r.uint32() ?? 0)
                versionPromise = nil
                continue
            }
            var r = SSHWireReader(Data(body))
            guard let id = r.uint32(), let promise = waiting.removeValue(forKey: id) else { continue }
            promise.succeed(Reply(type: type, body: Data(body.dropFirst(4))))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(SSHConnectionError.closed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failAll(SSHConnectionError.closed)
    }

    private func failAll(_ error: Error) {
        started.fail(error)
        versionPromise?.fail(error)
        versionPromise = nil
        let all = waiting.values
        waiting.removeAll()
        all.forEach { $0.fail(error) }
    }
}

public final class SFTPClient {

    enum Packet {
        static let initialize: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4,
                   read: UInt8 = 5, write: UInt8 = 6, lstat: UInt8 = 7, fsetstat: UInt8 = 10,
                   opendir: UInt8 = 11, readdir: UInt8 = 12, mkdir: UInt8 = 14, realpath: UInt8 = 16,
                   stat: UInt8 = 17, status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103,
                   name: UInt8 = 104, attrs: UInt8 = 105
    }

    static let read: UInt32 = 0x1, write: UInt32 = 0x2, create: UInt32 = 0x8, truncate: UInt32 = 0x10
    static let eof: UInt32 = 1

    /// Per read or write: what OpenSSH's own client uses.
    static let blockSize = 32 * 1024
    /// Requests in flight at once, so a slow link isn't paid per block.
    static let window = 16

    private let channel: Channel
    private let handler: SFTPChannelHandler
    private let timeout: TimeInterval
    private let host: String
    private let lock = NSLock()
    private var nextID: UInt32 = 1

    private init(channel: Channel, handler: SFTPChannelHandler, timeout: TimeInterval, host: String) {
        self.channel = channel
        self.handler = handler
        self.timeout = timeout
        self.host = host
    }

    /// Open the subsystem and agree a version. Blocks.
    public static func open(on connection: SSHConnection, timeout: TimeInterval) throws -> SFTPClient {
        var made: SFTPChannelHandler?
        let channel = try connection.openSession { child in
            let handler = SFTPChannelHandler(loop: child.eventLoop)
            made = handler
            try child.pipeline.syncOperations.addHandler(handler)
        }.waitBounded(timeout, host: connection.target.host)
        guard let handler = made else { throw SSHConnectionError.closed }
        let client = SFTPClient(channel: channel, handler: handler, timeout: timeout, host: connection.target.host)
        do {
            try handler.started.futureResult.waitBounded(timeout, host: client.host)
            let version = try channel.eventLoop.flatSubmit { () -> EventLoopFuture<UInt32> in
                let promise = channel.eventLoop.makePromise(of: UInt32.self)
                handler.versionPromise = promise
                var w = SSHWireWriter()
                w.byte(Packet.initialize)
                w.uint32(3)
                _ = handler.send(w.data, id: nil, context: nil, channel: channel)
                return promise.futureResult
            }.waitBounded(timeout, host: client.host)
            guard version >= 3 else { throw SSHConnectionError.rejected("SFTP version \(version) is too old") }
        } catch {
            client.close()
            throw error
        }
        return client
    }

    public func close() {
        channel.close(promise: nil)
    }

    // MARK: - Requests

    private func newID() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID &+= 1
        return id
    }

    /// Send one request; its reply as a future.
    private func request(_ type: UInt8, _ build: (inout SSHWireWriter) -> Void) -> EventLoopFuture<SFTPChannelHandler.Reply> {
        let id = newID()
        var w = SSHWireWriter()
        w.byte(type)
        w.uint32(id)
        build(&w)
        let packet = w.data
        let channel = self.channel
        let handler = self.handler
        return channel.eventLoop.flatSubmit {
            handler.send(packet, id: id, context: nil, channel: channel)
                ?? channel.eventLoop.makeFailedFuture(SSHConnectionError.closed)
        }
    }

    private func wait(_ future: EventLoopFuture<SFTPChannelHandler.Reply>) throws -> SFTPChannelHandler.Reply {
        try future.waitBounded(timeout, host: host)
    }

    /// The status in a reply, or nil when it isn't one.
    private func status(_ reply: SFTPChannelHandler.Reply, path: String) -> SFTPError? {
        guard reply.type == Packet.status else { return nil }
        var r = SSHWireReader(reply.body)
        let code = r.uint32() ?? 4
        let message = r.string() ?? ""
        return SFTPError(code: code, message: message, path: path)
    }

    private func expectOK(_ reply: SFTPChannelHandler.Reply, path: String) throws {
        guard let s = status(reply, path: path) else {
            throw SFTPError(code: 4, message: "unexpected reply \(reply.type)", path: path)
        }
        if s.code != 0 { throw s }
    }

    private func handle(_ reply: SFTPChannelHandler.Reply, path: String) throws -> Data {
        if reply.type == Packet.handle {
            var r = SSHWireReader(reply.body)
            if let h = r.data() { return h }
        }
        throw status(reply, path: path) ?? SFTPError(code: 4, message: "unexpected reply", path: path)
    }

    /// SFTP knows no `~`: a path written `~/x` means `x` in the home the
    /// session starts in.
    static func wirePath(_ path: String) -> String {
        if path == "~" { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path
    }

    public func stat(_ path: String) throws -> SFTPAttributes {
        let p = Self.wirePath(path)
        let reply = try wait(request(Packet.stat) { $0.string(p) })
        if reply.type == Packet.attrs {
            var r = SSHWireReader(reply.body)
            if let a = SFTPAttributes.decode(&r) { return a }
        }
        throw status(reply, path: path) ?? SFTPError(code: 4, message: "unexpected reply", path: path)
    }

    /// nil when there's nothing at `path`.
    public func statIfPresent(_ path: String) throws -> SFTPAttributes? {
        do { return try stat(path) } catch let e as SFTPError where e.code == SFTPError.noSuchFile { return nil }
    }

    public func mkdir(_ path: String, permissions: UInt32 = 0o755) throws {
        let p = Self.wirePath(path)
        try expectOK(wait(request(Packet.mkdir) { w in
            w.string(p)
            SFTPAttributes(permissions: permissions).encode(into: &w)
        }), path: path)
    }

    /// The names in a directory, without `.` and `..`.
    public func list(_ path: String) throws -> [(name: String, attributes: SFTPAttributes)] {
        let p = Self.wirePath(path)
        let h = try handle(wait(request(Packet.opendir) { $0.string(p) }), path: path)
        defer { _ = try? wait(request(Packet.close) { $0.data(h) }) }
        var entries: [(String, SFTPAttributes)] = []
        while true {
            let reply = try wait(request(Packet.readdir) { $0.data(h) })
            if let s = status(reply, path: path) {
                if s.code == Self.eof { break }
                throw s
            }
            guard reply.type == Packet.name else { break }
            var r = SSHWireReader(reply.body)
            let count = r.uint32() ?? 0
            for _ in 0..<count {
                guard let name = r.string(), r.string() != nil, let attrs = SFTPAttributes.decode(&r) else { break }
                if name != "." && name != ".." { entries.append((name, attrs)) }
            }
        }
        return entries
    }

    // MARK: - Files

    /// Write `data` to `path`, created or truncated, with the given mode
    /// and modification time.
    public func write(_ data: Data, to path: String, permissions: UInt32 = 0o644,
                      modificationTime: Date? = nil) throws {
        let p = Self.wirePath(path)
        let h = try handle(wait(request(Packet.open) { w in
            w.string(p)
            w.uint32(Self.write | Self.create | Self.truncate)
            SFTPAttributes(permissions: permissions).encode(into: &w)
        }), path: path)
        var failure: Error?
        var inFlight: [EventLoopFuture<SFTPChannelHandler.Reply>] = []
        var offset = 0
        func drainOne() throws {
            let reply = try wait(inFlight.removeFirst())
            try expectOK(reply, path: path)
        }
        do {
            while offset < data.count {
                let end = min(offset + Self.blockSize, data.count)
                let block = data.subdata(in: offset..<end)
                let at = UInt64(offset)
                inFlight.append(request(Packet.write) { w in
                    w.data(h)
                    w.uint64(at)
                    w.data(block)
                })
                offset = end
                if inFlight.count >= Self.window { try drainOne() }
            }
            while !inFlight.isEmpty { try drainOne() }
            if let modificationTime {
                let t = UInt32(max(0, modificationTime.timeIntervalSince1970))
                try expectOK(wait(request(Packet.fsetstat) { w in
                    w.data(h)
                    SFTPAttributes(accessTime: t, modificationTime: t).encode(into: &w)
                }), path: path)
            }
        } catch {
            failure = error
        }
        let closed = Result { try expectOK(wait(request(Packet.close) { $0.data(h) }), path: path) }
        if let failure { throw failure }
        try closed.get()
    }

    /// The whole of the file at `path`.
    public func read(_ path: String) throws -> (data: Data, attributes: SFTPAttributes) {
        let attributes = try stat(path)
        if attributes.isDirectory {
            throw SFTPError(code: 4, message: "not a regular file", path: path)
        }
        let p = Self.wirePath(path)
        let h = try handle(wait(request(Packet.open) { w in
            w.string(p)
            w.uint32(Self.read)
            SFTPAttributes().encode(into: &w)
        }), path: path)
        defer { _ = try? wait(request(Packet.close) { $0.data(h) }) }

        var result = Data()
        var offset: UInt64 = 0
        var finished = false
        while !finished {
            // A window of reads at successive offsets; a short or EOF
            // reply ends it.
            var batch: [(UInt64, EventLoopFuture<SFTPChannelHandler.Reply>)] = []
            for _ in 0..<Self.window {
                let at = offset
                batch.append((at, request(Packet.read) { w in
                    w.data(h)
                    w.uint64(at)
                    w.uint32(UInt32(Self.blockSize))
                }))
                offset += UInt64(Self.blockSize)
            }
            for (at, future) in batch {
                let reply = try wait(future)
                if finished { continue }
                if let s = status(reply, path: path) {
                    if s.code == Self.eof { finished = true; continue }
                    throw s
                }
                var r = SSHWireReader(reply.body)
                guard reply.type == Packet.data, let chunk = r.data() else {
                    throw SFTPError(code: 4, message: "unexpected reply", path: path)
                }
                guard UInt64(result.count) == at else {
                    // A short read before the end; sftp-server never sends one
                    // for a regular file, so it means the file is changing.
                    throw SFTPError(code: 4, message: "short read", path: path)
                }
                result.append(chunk)
                if chunk.count < Self.blockSize { finished = true }
            }
        }
        return (result, attributes)
    }
}
