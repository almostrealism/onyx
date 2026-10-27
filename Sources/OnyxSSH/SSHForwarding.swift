//
// SSHForwarding.swift
//
// Responsibility: Reverse port forwards (`ssh -R`): the server listens on a
//                 port and hands each connection to us, and we join it to a
//                 TCP port on this device. How agents on a host reach the
//                 app's MCP server (docs/ios-plan.md, phase 7).
// Scope: Per connection; a forward lives as long as the connection.
// Threading: Event loop.
//
// The joining is NIO's usual glue: two handlers, one in each channel, each
// writing what it reads into the other, with backpressure and half-close
// passed across.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Joins two channels: what one reads, the other writes.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}

/// An SSH channel's data as plain bytes, so it can be glued to a socket.
final class SSHChannelDataUnwrapper: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let bytes) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}

/// Where each of a connection's forwards delivers. Event loop only.
final class ForwardTable {
    private var targets: [Int: (host: String, port: Int)] = [:]

    func set(_ remotePort: Int, to target: (host: String, port: Int)?) { targets[remotePort] = target }

    /// Join a connection the server forwarded to its local target.
    func accept(_ child: Channel, _ type: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = type, let target = targets[info.listeningPort] else {
            return child.eventLoop.makeFailedFuture(SSHConnectionError.rejected("no forward for that port"))
        }
        let (ours, theirs) = GlueHandler.matchedPair()
        return child.pipeline.addHandlers([SSHChannelDataUnwrapper(), ours]).flatMap {
            ClientBootstrap(group: child.eventLoop)
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { local in local.pipeline.addHandler(theirs) }
                .connect(host: target.host, port: target.port)
                .map { _ in () }
        }
    }
}

extension SSHConnection {

    /// `ssh -R remotePort:localHost:localPort`: the server listens on
    /// `bindHost:remotePort` (0 = any free port) and each connection to it
    /// is joined to `localHost:localPort` here. Returns the port the server
    /// bound.
    public func forwardRemotePort(_ remotePort: Int, bindHost: String = "localhost",
                                  to localHost: String = "127.0.0.1", port localPort: Int) -> EventLoopFuture<Int> {
        requestRemoteForward(host: bindHost, port: remotePort).flatMap { [forwards] bound in
            self.channel.eventLoop.submit {
                forwards.set(bound, to: (localHost, localPort))
                return bound
            }
        }
    }

    /// Stop a forward.
    public func stopForwarding(_ remotePort: Int, bindHost: String = "localhost") {
        let forwards = self.forwards
        channel.eventLoop.execute { forwards.set(remotePort, to: nil) }
        cancelRemoteForward(host: bindHost, port: remotePort)
    }

    /// Is the server still answering? A global request it will refuse — a
    /// cancel for a forward that doesn't exist — and any answer, yes or no,
    /// means the connection is alive. The keepalive OpenSSH sends is the
    /// same idea (`keepalive@openssh.com`, which NIO SSH doesn't expose).
    public func ping(timeout: TimeInterval) -> EventLoopFuture<Bool> {
        let loop = channel.eventLoop
        let promise = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        let answered = loop.makePromise(of: Bool.self)
        loop.execute { [handler] in
            handler.sendTCPForwardingRequest(.cancel(host: "onyx-keepalive.invalid", port: 1), promise: promise)
        }
        promise.futureResult.whenComplete { result in
            switch result {
            case .success: answered.succeed(true)
            case .failure(let error):
                // Refused is an answer; a closed channel is not.
                answered.succeed(!(error is ChannelError) && self.isActive)
            }
        }
        let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) { answered.succeed(false) }
        answered.futureResult.whenComplete { _ in deadline.cancel() }
        return answered.futureResult
    }
}
