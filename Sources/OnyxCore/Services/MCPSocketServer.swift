//
// MCPSocketServer.swift
//
// Responsibility: Listening for the OnyxMCP bridge — newline-delimited
//                 JSON-RPC over loopback TCP (which hosts reach through a
//                 reverse forward of `defaultRemotePort`) and, on a Mac, a
//                 Unix socket — and handing each line to MCPMessageHandler.
// Scope: Service.
//

import Foundation
import Network

/// MCPSocketServer.
public class MCPSocketServer {
    private var unixListener: NWListener?
    private var tcpListener: NWListener?
    private let handler: MCPMessageHandler
    private let socketPath: String?

    /// The TCP port assigned by the OS after the listener starts (loopback only)
    public private(set) var tcpPort: UInt16?

    /// Called with the TCP port once it's listening.
    public var onReady: ((UInt16) -> Void)?

    /// Default remote-side port for SSH -R forwarding
    public static let defaultRemotePort: UInt16 = 19432

    /// `unixSocketPath`: also listen there, for agents on this machine
    /// (the Mac's ~/.onyx/mcp.sock). An iPad listens on loopback TCP only,
    /// for the reverse forwards.
    public init(handler: MCPMessageHandler, unixSocketPath: String? = nil) {
        self.handler = handler
        self.socketPath = unixSocketPath
    }

    /// Start.
    public func start() {
        startUnixSocket()
        startTCPListener()
    }

    private func startUnixSocket() {
        guard let socketPath else { return }
        unlink(socketPath)
        do {
            let params = NWParameters()
            params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
            params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

            unixListener = try NWListener(using: params)
            unixListener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            unixListener?.start(queue: .global(qos: .utility))
        } catch {
            print("MCP Unix socket failed to start: \(error)")
        }
    }

    private func startTCPListener() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)

            tcpListener = try NWListener(using: params)
            tcpListener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.tcpListener?.port {
                    self?.tcpPort = port.rawValue
                    self?.onReady?(port.rawValue)
                    print("MCP TCP listener ready on 127.0.0.1:\(port.rawValue)")
                }
            }
            tcpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            tcpListener?.start(queue: .global(qos: .utility))
        } catch {
            print("MCP TCP listener failed to start: \(error)")
        }
    }

    /// Stop.
    public func stop() {
        unixListener?.cancel()
        unixListener = nil
        tcpListener?.cancel()
        tcpListener = nil
        tcpPort = nil
        if let socketPath { unlink(socketPath) }
    }

    private func handleConnection(_ connection: NWConnection) {
        // Always cancel on terminal states so we don't leak fds in
        // CLOSE_WAIT when the peer (OnyxMCP) goes away. Without this the
        // SSH -R forward accumulates dead connections that block new ones.
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) { [weak self] content, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let data = content, !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    for line in text.components(separatedBy: "\n") where !line.isEmpty {
                        if let msgData = line.data(using: .utf8),
                           let response = self.handler.handleMessage(msgData) {
                            let responseWithNewline = response + Data("\n".utf8)
                            connection.send(content: responseWithNewline, completion: .contentProcessed { _ in })
                        }
                    }
                }
            }
            if isComplete || error != nil {
                // Peer closed (FIN) or hard error — close our end too.
                // This is what was missing and causing the CLOSE_WAIT pile-up.
                connection.cancel()
                return
            }
            self.receiveMessage(on: connection)
        }
    }
}
