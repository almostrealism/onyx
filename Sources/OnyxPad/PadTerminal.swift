//
// PadTerminal.swift
//
// Responsibility: One open terminal on the iPad — a tmux session attached
//                 over the built-in SSH client — and the set of them a
//                 window has open.
// Scope: PadTerminal per open session; PadWorkspace per window (scene).
// Threading: Main thread. Output arrives on a background queue and is
//            handed to the view on main.
//
// The terminal outlives its view: switching tabs, or a window going to the
// background, must not lose the screen. So the UIKit view is kept here
// (`hostView`) and output that arrives with no view attached is held until
// one is.
//

import Foundation
import Combine
import OnyxCore

public final class PadTerminal: ObservableObject, Identifiable {

    public enum State: Equatable {
        case connecting
        case live
        /// tmux detached, the connection went, or it never started.
        case ended(String)
    }

    public let id = UUID()
    public let session: TmuxSession
    public let host: PadHost
    @Published public private(set) var state: State = .connecting
    /// The window title tmux sets, when it sets one.
    @Published public var title: String?

    /// The platform view showing this terminal, kept across tab switches.
    public var hostView: AnyObject?
    /// Where screen bytes go, on main. Set by the view.
    public var output: ((Data) -> Void)? {
        didSet { flushPending() }
    }

    private var remote: RemoteTerminal?
    private var pending = Data()
    private var size = (columns: 80, rows: 24)
    /// Output held with no view to draw it: enough to repaint tmux.
    static let pendingLimit = 1 << 20

    public init(session: TmuxSession, host: PadHost) {
        self.session = session
        self.host = host
    }

    /// Attach. Again after it ended: tmux kept the session.
    public func start(using provider: RemoteTerminalProvider) {
        guard let connection = host.connection else {
            state = .ended("\(host.label) isn't set up for iPad yet — on your Mac: Settings → Shared state → Set up every host for iPad.")
            return
        }
        remote?.close()
        state = .connecting
        let command = TmuxSessions.attachCommand(session.name)
        var opened: RemoteTerminal?
        opened = provider.openTerminal(command, on: connection, columns: size.columns, rows: size.rows,
                                       term: "xterm-256color",
                                       onOutput: { [weak self] data in
                                           DispatchQueue.main.async { self?.receive(data, from: opened) }
                                       },
                                       onEnd: { [weak self] end in
                                           DispatchQueue.main.async { self?.ended(end, from: opened) }
                                       })
        remote = opened
    }

    public func send(_ data: Data) {
        remote?.send(data)
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, (columns, rows) != size else { return }
        size = (columns, rows)
        remote?.resize(columns: columns, rows: rows)
    }

    /// Hang up. The tmux session carries on.
    public func close() {
        remote?.close()
        remote = nil
    }

    private func receive(_ data: Data, from terminal: RemoteTerminal?) {
        guard terminal === remote else { return }
        if state == .connecting { state = .live }
        if let output {
            output(data)
        } else {
            pending.append(data)
            if pending.count > Self.pendingLimit { pending.removeFirst(pending.count - Self.pendingLimit) }
        }
    }

    private func ended(_ end: RemoteTerminalEnd, from terminal: RemoteTerminal?) {
        guard terminal === remote else { return }
        remote = nil
        switch end {
        case .exited(let code):
            state = .ended(code == 0 ? "Detached from \(session.name)." : "\(session.name) ended (exit \(code)).")
        case .failed(let why):
            state = .ended(why.isEmpty ? "The connection to \(host.label) went." : why)
        }
    }

    private func flushPending() {
        guard let output, !pending.isEmpty else { return }
        let held = pending
        pending = Data()
        output(held)
    }
}

/// The terminals one window has open, and which is in front.
public final class PadWorkspace: ObservableObject {

    public enum Selection: Hashable {
        case today
        case terminal(UUID)
    }

    @Published public private(set) var terminals: [PadTerminal] = []
    @Published public var selection: Selection = .today

    public init() {}

    public var current: PadTerminal? {
        guard case .terminal(let id) = selection else { return nil }
        return terminals.first { $0.id == id }
    }

    /// Bring the session to the front, attaching if it isn't open here.
    @discardableResult
    public func open(_ session: TmuxSession, on host: PadHost, using provider: RemoteTerminalProvider) -> PadTerminal {
        if let open = terminals.first(where: { $0.session.id == session.id }) {
            if case .ended = open.state { open.start(using: provider) }
            selection = .terminal(open.id)
            return open
        }
        let terminal = PadTerminal(session: session, host: host)
        terminals.append(terminal)
        terminal.start(using: provider)
        selection = .terminal(terminal.id)
        return terminal
    }

    public func close(_ terminal: PadTerminal) {
        terminal.close()
        guard let index = terminals.firstIndex(where: { $0.id == terminal.id }) else { return }
        terminals.remove(at: index)
        if selection == .terminal(terminal.id) {
            let next = terminals.indices.contains(index) ? terminals[index]
                : terminals.last
            selection = next.map { .terminal($0.id) } ?? .today
        }
    }

    /// The next or previous tab (⌘⇧] and ⌘⇧[).
    public func cycle(by step: Int) {
        let order: [Selection] = [.today] + terminals.map { .terminal($0.id) }
        guard let at = order.firstIndex(of: selection), order.count > 1 else { return }
        selection = order[(at + step + order.count) % order.count]
    }

    /// The window is going away: hang up its terminals.
    public func closeAll() {
        for terminal in terminals { terminal.close() }
    }
}
