//
// SSHConnection.swift
//
// Responsibility: One authenticated SSH connection to one host, made in
//                 process with SwiftNIO SSH — the only kind of connection
//                 iOS can have (docs/ios-plan.md, phase 2). Sessions (exec,
//                 shell, subsystem) ride it as channels, the way the Mac's
//                 ssh processes ride a ControlMaster.
// Scope: One per host, owned by NIOTransport's pool.
// Threading: Everything NIO happens on the connection's event loop; the
//            public calls hop there themselves.
//
// Failures read like OpenSSH's own (`SSHConnectionError.description`),
// because the code above was written against those messages and because
// a user who has seen "Permission denied (publickey)" knows what it means.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import OnyxCore

/// The event loops every connection shares. Two threads: SSH is cheap, and
/// a connection's work stays on the loop it was made on.
public enum SSHRuntime {
    public static let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
}

public enum SSHConnectionError: Error, Equatable, CustomStringConvertible {
    /// TCP never connected (refused, unreachable, no such host).
    case unreachable(host: String, port: Int, reason: String)
    case hostKeyChanged(host: String, presented: String)
    /// Every key was refused, or there were none to offer.
    case authenticationFailed(user: String, host: String, tried: [String])
    /// No user name for the host, and no account to default to.
    case noUser(host: String)
    case timedOut(host: String)
    /// The server refused a channel or a request on it.
    case rejected(String)
    /// The connection went away underneath us.
    case closed

    /// In OpenSSH's words where it has some: `isTransportFailure` callers
    /// and people both recognize them.
    public var description: String {
        switch self {
        case .unreachable(let host, let port, let reason):
            return "ssh: connect to host \(host) port \(port): \(reason)"
        case .hostKeyChanged(let host, let presented):
            return """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            The host key for \(host) is not the one on record; it now presents
            \(presented)
            Host key verification failed.
            """
        case .authenticationFailed(let user, let host, let tried):
            let keys = tried.isEmpty ? "no usable key" : "tried " + tried.joined(separator: ", ")
            return "\(user)@\(host): Permission denied (publickey) — \(keys)."
        case .noUser(let host):
            return "ssh: no user name set for \(host)"
        case .timedOut(let host):
            return "ssh: connect to host \(host): Operation timed out"
        case .rejected(let what):
            return "ssh: \(what)"
        case .closed:
            return "Connection closed by remote host"
        }
    }
}

/// Where to connect and as whom.
public struct SSHTarget {
    public let host: String
    public let port: Int
    public let user: String
    public let identities: [SSHIdentity]
    /// Why a key the user has couldn't be offered, for the failure message.
    public let skippedKeys: [String]

    public init(host: String, port: Int, user: String, identities: [SSHIdentity], skippedKeys: [String] = []) {
        self.host = host
        self.port = port
        self.user = user
        self.identities = identities
        self.skippedKeys = skippedKeys
    }

    /// The pool's key: one connection per host, port and user.
    var poolKey: String { "\(user)@\(host):\(port)" }
}

/// Offers each identity in turn; out of keys, fails with what was tried.
final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let target: SSHTarget
    private var remaining: [SSHIdentity]
    private var tried: [String] = []

    init(target: SSHTarget) {
        self.target = target
        self.remaining = target.identities
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !remaining.isEmpty else {
            nextChallengePromise.fail(SSHConnectionError.authenticationFailed(
                user: target.user, host: target.host, tried: tried + target.skippedKeys))
            return
        }
        let next = remaining.removeFirst()
        tried.append(next.source)
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: target.user, serviceName: "",
            offer: .privateKey(.init(privateKey: next.privateKey))))
    }
}

/// Turns the connection's progress into one future: succeeded once the
/// user is signed in, failed with the first error otherwise.
final class AuthenticationWaiter: ChannelInboundHandler {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>
    private var firstError: Error?

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if firstError == nil { firstError = error }
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(firstError ?? SSHConnectionError.closed)
        context.fireChannelInactive()
    }
}

public final class SSHConnection {

    public let target: SSHTarget
    let channel: Channel
    private let handler: NIOSSHHandler

    /// Called (on the event loop) with each channel the server opens to
    /// us — a reverse forward's connections (phase 4). Rejected without one.
    var onInboundChannel: ((Channel, SSHChannelType) -> EventLoopFuture<Void>)?

    public var isActive: Bool { channel.isActive }
    public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    private init(target: SSHTarget, channel: Channel, handler: NIOSSHHandler) {
        self.target = target
        self.channel = channel
        self.handler = handler
    }

    /// Connect, check the host key against `knownHosts`, sign in. Blocks
    /// the caller (never call on an event loop) for at most `timeout`.
    public static func connect(_ target: SSHTarget, knownHosts: KnownHostsStore,
                               timeout: TimeInterval) throws -> SSHConnection {
        try connectFuture(target, knownHosts: knownHosts, timeout: timeout).waitBounded(timeout + 1, host: target.host)
    }

    static func connectFuture(_ target: SSHTarget, knownHosts: KnownHostsStore,
                              timeout: TimeInterval) -> EventLoopFuture<SSHConnection> {
        let loop = SSHRuntime.group.next()
        let signedIn = loop.makePromise(of: Void.self)
        let verifier = KnownHostsVerifier(store: knownHosts, host: target.host, port: target.port)
        // Set once the channel exists; inbound channels are routed through it.
        let box = InboundRouter()

        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.milliseconds(Int64(max(timeout, 1) * 1000)))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(
                        userAuthDelegate: PublicKeyAuthDelegate(target: target),
                        serverAuthDelegate: verifier)
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator,
                                            inboundChildChannelInitializer: { child, type in
                        box.route(child, type)
                    })
                    try channel.pipeline.syncOperations.addHandlers(ssh, AuthenticationWaiter(promise: signedIn))
                }
            }

        let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            signedIn.fail(SSHConnectionError.timedOut(host: target.host))
        }

        return bootstrap.connect(host: target.host, port: target.port)
            .flatMapErrorThrowing { error in
                throw SSHConnectionError.unreachable(host: target.host, port: target.port,
                                                     reason: Self.reason(error))
            }
            .flatMap { channel in
                signedIn.futureResult
                    .flatMapErrorThrowing { error in
                        channel.close(promise: nil)
                        throw Self.translate(error, verifier: verifier)
                    }
                    .flatMap {
                        channel.pipeline.handler(type: NIOSSHHandler.self).map { handler in
                            let connection = SSHConnection(target: target, channel: channel, handler: handler)
                            box.connection = connection
                            return connection
                        }
                    }
            }
            .always { _ in
                deadline.cancel()
                // A connect that failed before the handshake leaves it
                // pending, and NIO rightly treats a dropped promise as a bug.
                signedIn.fail(SSHConnectionError.closed)
            }
    }

    /// Our error if we raised one (host key, keys refused), else a
    /// readable account of NIO's.
    private static func translate(_ error: Error, verifier: KnownHostsVerifier) -> Error {
        if let mine = error as? SSHConnectionError { return mine }
        if case .changed(let expected)? = verifier.verdict {
            return SSHConnectionError.hostKeyChanged(host: "the server", presented: expected)
        }
        return SSHConnectionError.rejected(String(describing: error))
    }

    private static func reason(_ error: Error) -> String {
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return "Connection refused"
            case EHOSTUNREACH: return "No route to host"
            case ENETUNREACH: return "Network is unreachable"
            case ETIMEDOUT: return "Operation timed out"
            default: return String(cString: strerror(io.errnoCode))
            }
        }
        if error is ChannelError { return "Operation timed out" }
        if let resolution = error as? NIOConnectionError {
            if resolution.dnsAAAAError != nil || resolution.dnsAError != nil, resolution.connectionErrors.isEmpty {
                return "nodename nor servname provided, or not known"
            }
            if let first = resolution.connectionErrors.first { return reason(first.error) }
        }
        return String(describing: error)
    }

    /// Open a session channel with `handler` at the end of its pipeline.
    func openSession(_ initializer: @escaping (Channel) throws -> Void) -> EventLoopFuture<Channel> {
        let loop = channel.eventLoop
        let promise = loop.makePromise(of: Channel.self)
        loop.execute { [handler] in
            handler.createChannel(promise, channelType: .session) { child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(SSHConnectionError.rejected("unexpected channel type"))
                }
                return child.eventLoop.makeCompletedFuture { try initializer(child) }
            }
        }
        return promise.futureResult
    }

    /// Ask the server to listen on `port` and send us its connections
    /// (`ssh -R`). Returns the port bound.
    func requestRemoteForward(host: String, port: Int) -> EventLoopFuture<Int> {
        let loop = channel.eventLoop
        let promise = loop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        loop.execute { [handler] in
            handler.sendTCPForwardingRequest(.listen(host: host, port: port), promise: promise)
        }
        return promise.futureResult.map { $0?.boundPort ?? port }
    }

    func cancelRemoteForward(host: String, port: Int) {
        let loop = channel.eventLoop
        loop.execute { [handler] in
            handler.sendTCPForwardingRequest(.cancel(host: host, port: port), promise: nil)
        }
    }

    public func close() {
        channel.close(promise: nil)
    }
}

/// Holds the connection for the NIOSSHHandler's inbound-channel callback,
/// which is made before the connection exists.
private final class InboundRouter {
    weak var connection: SSHConnection?

    func route(_ child: Channel, _ type: SSHChannelType) -> EventLoopFuture<Void> {
        guard let handler = connection?.onInboundChannel else {
            return child.eventLoop.makeFailedFuture(SSHConnectionError.rejected("channel refused"))
        }
        return handler(child, type)
    }
}

extension EventLoopFuture {
    /// `wait()` with a ceiling: a future NIO never completes must not hang
    /// a worker thread forever.
    func waitBounded(_ seconds: TimeInterval, host: String) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Value, Error>?
        whenComplete { r in
            result = r
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + seconds) == .success, let result else {
            throw SSHConnectionError.timedOut(host: host)
        }
        return try result.get()
    }
}
