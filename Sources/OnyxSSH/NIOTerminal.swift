//
// NIOTerminal.swift
//
// Responsibility: RemoteTerminal over the built-in client — a session
//                 channel with a PTY, its output handed over as it comes,
//                 keystrokes written as they're typed.
// Scope: One per terminal.
// Threading: Any thread in; callbacks on the event loop's thread, never
//            blocking it.
//

import Foundation
import NIOCore
import NIOSSH
import OnyxCore

final class NIOTerminal: RemoteTerminal {
    private let lock = NSLock()
    private var session: SSHSession?
    /// Input typed before the channel was up.
    private var held = Data()
    private var size: (columns: Int, rows: Int)
    private var closed = false
    private var ended = false
    private let onEnd: (RemoteTerminalEnd) -> Void

    init(columns: Int, rows: Int, onEnd: @escaping (RemoteTerminalEnd) -> Void) {
        size = (columns, rows)
        self.onEnd = onEnd
    }

    func attach(_ session: SSHSession) {
        lock.lock()
        if closed {
            lock.unlock()
            session.terminate()
            return
        }
        self.session = session
        let pending = held
        held = Data()
        let current = size
        lock.unlock()
        if !pending.isEmpty { session.write(pending) }
        session.resize(columns: current.columns, rows: current.rows)
        // Strongly: a caller that keeps no reference to the terminal still
        // gets its end — the future lets go once it has fired.
        session.exitStatus.whenComplete { result in
            self.end(.exited((try? result.get()) ?? 255))
        }
    }

    func end(_ how: RemoteTerminalEnd) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        lock.unlock()
        onEnd(how)
    }

    func send(_ data: Data) {
        lock.lock()
        guard let session else {
            if !closed { held.append(data) }
            lock.unlock()
            return
        }
        lock.unlock()
        session.write(data)
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        size = (columns, rows)
        let session = self.session
        lock.unlock()
        session?.resize(columns: columns, rows: rows)
    }

    func close() {
        lock.lock()
        closed = true
        let session = self.session
        lock.unlock()
        session?.close()
        if session == nil { end(.exited(-1)) }
    }
}

extension NIOTransport: RemoteTerminalProvider {

    public func openTerminal(_ command: String?, on host: HostConfig,
                             columns: Int, rows: Int, term: String,
                             onOutput: @escaping (Data) -> Void,
                             onEnd: @escaping (RemoteTerminalEnd) -> Void) -> RemoteTerminal {
        let terminal = NIOTerminal(columns: columns, rows: rows, onEnd: onEnd)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let request: SSHSessionRequest = command.map { .exec(RemoteWire.execCommand($0)) } ?? .shell
                let session = try withTerminalConnection(host) { connection in
                    try connection.startSession(
                        request, terminal: SSHTerminalSize(columns: columns, rows: rows, term: term),
                        stdin: .none,
                        onStdout: { buffer in
                            var b = buffer
                            if let bytes = b.readBytes(length: b.readableBytes) { onOutput(Data(bytes)) }
                        },
                        onStderr: { buffer in
                            var b = buffer
                            if let bytes = b.readBytes(length: b.readableBytes) { onOutput(Data(bytes)) }
                        })
                        .waitBounded(20, host: connection.target.host)
                }
                terminal.attach(session)
            } catch {
                terminal.end(.failed(Self.output(for: error).stderr))
            }
        }
        return terminal
    }
}
