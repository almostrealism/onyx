//
// EngineTransport.swift
//
// Responsibility: The Mac's RemoteTransport: each call goes to OpenSSH
//                 (ProcessTransport) or the built-in client (NIOTransport)
//                 by the user's choice, decided per call so switching in
//                 Settings takes effect at once. Local hosts always run as
//                 processes — the built-in client has no "here".
// Scope: One per AppState.
//

import Foundation
import OnyxCore
import OnyxSSH

final class EngineTransport: RemoteTransport {

    let process: RemoteTransport
    let builtIn: RemoteTransport
    private let engine: () -> SSHEngine

    init(process: RemoteTransport, builtIn: RemoteTransport, engine: @escaping () -> SSHEngine) {
        self.process = process
        self.builtIn = builtIn
        self.engine = engine
    }

    var name: String { engine() == .builtIn ? builtIn.name : process.name }

    /// Who carries a call to `host`.
    func route(_ host: HostConfig) -> RemoteTransport {
        host.isLocal || engine() != .builtIn ? process : builtIn
    }

    func execute(_ invocation: RemoteInvocation, on host: HostConfig,
                 timeout: TimeInterval, label: String) -> RemoteOutput {
        route(host).execute(invocation, on: host, timeout: timeout, label: label)
    }

    @discardableResult
    func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
               label: String, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) -> RemoteJob {
        route(host).start(invocation, on: host, timeout: timeout, label: label,
                          onOutput: onOutput, onExit: onExit)
    }

    func upload(_ localPath: String, to remotePath: String, on host: HostConfig,
                recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        route(host).upload(localPath, to: remotePath, on: host, recursive: recursive,
                           timeout: timeout, label: label)
    }

    func download(_ remotePath: String, to localPath: String, from host: HostConfig,
                  recursive: Bool, timeout: TimeInterval, label: String) -> RemoteOutput {
        route(host).download(remotePath, to: localPath, from: host, recursive: recursive,
                             timeout: timeout, label: label)
    }
}
