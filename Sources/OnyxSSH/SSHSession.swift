//
// SSHSession.swift
//
// Responsibility: One session channel — an exec, a shell or a subsystem —
//                 from request to exit status: stdin in (paced, for a
//                 terminal), stdout and stderr out as they arrive.
// Scope: One per remote run.
// Threading: The handler lives on the connection's event loop; callbacks
//            are made there, so they must not block.
//
// What OpenSSH's client does for `ssh host cmd`, `ssh -T host < script`
// and `ssh -tt host < script` respectively — the three deliveries
// RemoteInvocation names — so the remote side can't tell the difference.
//

import Foundation
import NIOCore
import NIOSSH

/// What a session asks the server to run.
public enum SSHSessionRequest: Equatable {
    case exec(String)
    case shell
    case subsystem(String)
}

/// A terminal for the session (`ssh -t`).
public struct SSHTerminalSize: Equatable {
    public var columns: Int
    public var rows: Int
    public var term: String

    public init(columns: Int = 200, rows: Int = 50, term: String = "xterm-256color") {
        self.columns = columns
        self.rows = rows
        self.term = term
    }
}

/// How stdin is delivered.
public enum SSHStdin {
    case none
    /// All at once, then EOF.
    case piped(Data)
    /// In `chunk`-byte pieces `pause` apart, then EOF: a terminal's input
    /// queue (~1KB) drops whatever arrives faster than the shell reads it.
    case paced(Data, chunk: Int, pause: TimeInterval)
}

final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let request: SSHSessionRequest
    private let terminal: SSHTerminalSize?
    private let stdin: SSHStdin
    private let onStdout: (ByteBuffer) -> Void
    private let onStderr: (ByteBuffer) -> Void
    /// Succeeds once the server accepts the request; fails if it refuses.
    let started: EventLoopPromise<Void>
    /// The exit status, once the channel closes.
    let exited: EventLoopPromise<Int32>
    private var exitStatus: Int32?

    init(request: SSHSessionRequest, terminal: SSHTerminalSize?, stdin: SSHStdin,
         loop: EventLoop,
         onStdout: @escaping (ByteBuffer) -> Void, onStderr: @escaping (ByteBuffer) -> Void) {
        self.request = request
        self.terminal = terminal
        self.stdin = stdin
        self.onStdout = onStdout
        self.onStderr = onStderr
        self.started = loop.makePromise()
        self.exited = loop.makePromise()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Without this, the server's EOF closes the channel before its
        // exit status arrives.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        if let terminal {
            var modes = SSHTerminalModes([:])
            modes.modeMapping[.ECHO] = 1
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: false, term: terminal.term,
                terminalCharacterWidth: terminal.columns, terminalRowHeight: terminal.rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: modes)
            context.triggerUserOutboundEvent(pty, promise: nil)
        }
        let event: Any
        switch request {
        case .exec(let command): event = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        case .shell: event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        case .subsystem(let name): event = SSHChannelRequestEvent.SubsystemRequest(subsystem: name, wantReply: true)
        }
        context.triggerUserOutboundEvent(event).whenFailure { [started] error in
            started.fail(error)
            context.close(promise: nil)
        }
        sendStdin(context: context)
        context.fireChannelActive()
    }

    private func sendStdin(context: ChannelHandlerContext) {
        switch stdin {
        case .none:
            break
        case .piped(let data):
            write(data, context: context)
            context.close(mode: .output, promise: nil)
        case .paced(let data, let chunk, let pause):
            pace(data[...], chunk: chunk, pause: pause, context: context)
        }
    }

    private func pace(_ rest: Data.SubSequence, chunk: Int, pause: TimeInterval, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        guard !rest.isEmpty else {
            context.close(mode: .output, promise: nil)
            return
        }
        write(Data(rest.prefix(chunk)), context: context)
        let next = rest.dropFirst(chunk)
        context.eventLoop.scheduleTask(in: .milliseconds(Int64(pause * 1000))) { [self] in
            self.pace(next, chunk: chunk, pause: pause, context: context)
        }
    }

    private func write(_ data: Data, context: ChannelHandlerContext) {
        guard !data.isEmpty else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
                              promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        switch message.type {
        case .channel: onStdout(bytes)
        case .stdErr: onStderr(bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            started.succeed(())
        case is ChannelFailureEvent:
            started.fail(SSHConnectionError.rejected(rejection))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = Int32(truncatingIfNeeded: status.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            // ssh exits 255 when the remote command dies of a signal.
            exitStatus = 255
            if !signal.errorMessage.isEmpty {
                var b = context.channel.allocator.buffer(capacity: signal.errorMessage.utf8.count)
                b.writeString(signal.errorMessage)
                onStderr(b)
            }
        case ChannelEvent.inputClosed:
            // The server's EOF. Its exit status may still be on the way;
            // the channel close that follows is what ends the run.
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private var rejection: String {
        switch request {
        case .exec: return "the server refused to run the command"
        case .shell: return "the server refused a shell"
        case .subsystem(let name): return "subsystem request failed on channel 0 (\(name))"
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        started.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        started.fail(SSHConnectionError.closed)
        // No status at all means the connection, not the command, ended it.
        exited.succeed(exitStatus ?? 255)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        started.fail(SSHConnectionError.closed)
        exited.succeed(exitStatus ?? 255)
    }
}

/// A running session: cancel it, wait for it.
public final class SSHSession {
    let channel: Channel
    public let exitStatus: EventLoopFuture<Int32>
    public let started: EventLoopFuture<Void>

    init(channel: Channel, handler: SessionHandler) {
        self.channel = channel
        self.exitStatus = handler.exited.futureResult
        self.started = handler.started.futureResult
    }

    /// Write to stdin (an interactive terminal's keystrokes).
    public func write(_ data: Data) {
        let channel = self.channel
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
    }

    /// Tell the server the terminal changed size.
    public func resize(columns: Int, rows: Int) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    public func close() {
        channel.close(promise: nil)
    }

    /// End it now. Closing alone isn't enough: sshd keeps a session whose
    /// command still holds its output open (`sleep 30` keeps the channel
    /// for 30 seconds), so the command is sent SIGTERM first — and
    /// SIGHUP, for servers that ignore signal requests but close a
    /// terminal's session on hangup.
    public func terminate() {
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SignalRequest(signal: "TERM"), promise: nil)
        channel.close(promise: nil)
    }
}

extension SSHConnection {

    /// Start a session. `onStdout`/`onStderr` are called on the event loop.
    public func startSession(_ request: SSHSessionRequest, terminal: SSHTerminalSize? = nil,
                             stdin: SSHStdin = .none,
                             onStdout: @escaping (ByteBuffer) -> Void,
                             onStderr: @escaping (ByteBuffer) -> Void) -> EventLoopFuture<SSHSession> {
        var made: SessionHandler?
        return openSession { child in
            let handler = SessionHandler(request: request, terminal: terminal, stdin: stdin,
                                         loop: child.eventLoop, onStdout: onStdout, onStderr: onStderr)
            made = handler
            try child.pipeline.syncOperations.addHandler(handler)
        }.flatMapThrowing { child in
            guard let handler = made else { throw SSHConnectionError.closed }
            return SSHSession(channel: child, handler: handler)
        }
    }
}
