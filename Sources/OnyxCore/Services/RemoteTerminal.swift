//
// RemoteTerminal.swift
//
// Responsibility: An interactive terminal on a host — keystrokes in,
//                 screen bytes out, a size — independent of what carries
//                 it. The iPad's terminals are this over the built-in SSH
//                 client (docs/ios-plan.md, phase 5); the Mac's are still
//                 `ssh` processes inside SwiftTerm's LocalProcessTerminalView.
// Scope: Protocols.
//

import Foundation

/// How a terminal ended.
public enum RemoteTerminalEnd: Equatable, Sendable {
    /// The remote program exited (tmux detached, the shell ended).
    case exited(Int32)
    /// It never started, or the connection went: in ssh's words.
    case failed(String)
}

/// A live terminal. Calls may be made from any thread.
public protocol RemoteTerminal: AnyObject {
    /// Keystrokes, pastes — bytes for the remote program.
    func send(_ data: Data)
    /// The window changed size.
    func resize(columns: Int, rows: Int)
    /// Hang up.
    func close()
}

/// What can open one.
public protocol RemoteTerminalProvider: AnyObject {
    /// Start `command` (nil: the login shell) on `host` in a terminal of
    /// the given size. Returns at once; output and the end arrive on a
    /// background queue, `onEnd` exactly once. Input sent before the
    /// terminal is up is held and delivered when it is.
    func openTerminal(_ command: String?, on host: HostConfig,
                      columns: Int, rows: Int, term: String,
                      onOutput: @escaping (Data) -> Void,
                      onEnd: @escaping (RemoteTerminalEnd) -> Void) -> RemoteTerminal
}
