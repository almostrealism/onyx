//
// PadAgents.swift
//
// Responsibility: Agents on your hosts reaching this iPad while Onyx is
//                 open — the same MCP server a Mac runs (OnyxCore), a
//                 reverse forward of the bridge's port on each host, alerts
//                 from `notify`, pages from `show_html`/`show_text`, and
//                 Claude's hooks (sessions, and permission prompts that
//                 wait for the iPad's sheet).
// Scope: One per app.
// Threading: Main thread; the server answers on its own queue.
//
// docs/ios-plan.md, phase 7. A host's agents reach ONE Onyx: whoever holds
// port 19432 there. A Mac connected to the host holds it already, and then
// the forward from here fails and the agents keep talking to the Mac — the
// sidebar says so. While the iPad holds it, a Mac that connects later finds
// it taken (its forward is `ExitOnForwardFailure=no`) until the iPad lets
// go, which iOS does for it soon after the app leaves the screen.
//

import Foundation
import Combine
import OnyxCore
import OnyxSSH

/// An agent's `notify`, as the iPad shows it.
public struct PadAlert: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let body: String?
    public let host: String?
    public let session: String?
    public let urgent: Bool
    public let at: Date
}

/// An agent's page: HTML to show in a web tab.
public struct PadPage: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let html: String
}

public final class PadAgents: ObservableObject {

    public enum Reach: Equatable {
        case connecting
        /// Agents on the host reach this iPad.
        case reaching
        /// The port is held on the host — by a Mac, most likely.
        case elsewhere(String)
        case failed(String)
    }

    @Published public private(set) var reach: [UUID: Reach] = [:]
    @Published public private(set) var alerts: [PadAlert] = []
    /// A page waiting for a window to show it. The first window to see it
    /// takes it (`takePage`), so two windows don't both open it.
    @Published public private(set) var pendingPage: PadPage?

    public let sessions = ClaudeSessionManager.shared
    private let transport: NIOTransport
    private var server: MCPSocketServer?
    private var localPort: UInt16?
    private var inFlight: Set<UUID> = []
    private var waiting: [PadHost] = []
    /// The port the bridge looks for on each host. A Debug build takes
    /// another (`ONYX_PAD_MCP_PORT`), so a demo can't capture the agents
    /// of the machine it runs on.
    let remotePort: Int

    public init(transport: NIOTransport, remotePort: Int = Int(MCPSocketServer.defaultRemotePort)) {
        self.transport = transport
        #if DEBUG
        self.remotePort = ProcessInfo.processInfo.environment["ONYX_PAD_MCP_PORT"].flatMap(Int.init) ?? remotePort
        #else
        self.remotePort = remotePort
        #endif
    }

    /// Listen. Once; hosts are reached as they're listed.
    public func start() {
        guard server == nil else { return }
        let tools = PadMCPTools(agents: self)
        let server = MCPSocketServer(handler: MCPMessageHandler(tools: tools, claudeSessions: sessions))
        server.onReady = { [weak self] port in
            DispatchQueue.main.async {
                guard let self else { return }
                self.localPort = port
                let queued = self.waiting
                self.waiting = []
                for host in queued { self.reachAgents(on: host) }
            }
        }
        server.start()
        self.server = server
        sessions.attention = (
            begin: {
                PadNotifier.post(title: "An agent is waiting for you",
                                 body: "A permission prompt is open in Onyx.", id: "permission")
            },
            end: {})
    }

    /// Forward the bridge's port on `host` to this iPad, unless it's
    /// already reaching here over a live connection.
    public func reachAgents(on host: PadHost) {
        guard let connection = host.connection, !inFlight.contains(host.id) else { return }
        guard let localPort else {
            if !waiting.contains(where: { $0.id == host.id }) { waiting.append(host) }
            return
        }
        if reach[host.id] == .reaching, transport.isConnected(connection) { return }
        if case .elsewhere = reach[host.id], transport.isConnected(connection) { return }
        inFlight.insert(host.id)
        if reach[host.id] == nil { reach[host.id] = .connecting }
        let transport = self.transport, remote = remotePort
        DispatchQueue.global(qos: .utility).async {
            let outcome: Reach
            do {
                _ = try transport.forwardRemotePort(remote, on: connection, toLocalPort: Int(localPort))
                outcome = .reaching
            } catch {
                outcome = transport.isConnected(connection)
                    ? .elsewhere("port \(remote) is taken on \(host.label) — your Mac, most likely")
                    : .failed("\(error)")
            }
            DispatchQueue.main.async {
                self.inFlight.remove(host.id)
                self.reach[host.id] = outcome
            }
        }
    }

    // MARK: - What the tools deliver

    func received(_ alert: PadAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > 50 { alerts.removeLast(alerts.count - 50) }
        let place = [alert.session, alert.host].compactMap { $0 }.joined(separator: " on ")
        PadNotifier.post(title: alert.title, body: [alert.body, place.isEmpty ? nil : place]
                            .compactMap { $0 }.joined(separator: "\n"),
                         id: alert.session ?? "agent")
    }

    func received(_ page: PadPage) {
        pendingPage = page
    }

    private var takenPages: Set<UUID> = []

    /// A window shows the page; nobody else does. Takes the page itself,
    /// because `$pendingPage` delivers it before the property changes.
    public func take(_ page: PadPage) -> Bool {
        guard takenPages.insert(page.id).inserted else { return false }
        DispatchQueue.main.async { if self.pendingPage?.id == page.id { self.pendingPage = nil } }
        return true
    }

    public func dismiss(_ alert: PadAlert) {
        alerts.removeAll { $0.id == alert.id }
    }
}

/// What the iPad offers agents besides what every Onyx does.
final class PadMCPTools: MCPToolHost {
    private weak var agents: PadAgents?

    init(agents: PadAgents) {
        self.agents = agents
    }

    var machineName: String { SharedStateSync.deviceName ?? "iPad" }

    var toolDefinitions: [AnyCodableValue] {
        [MCPTools.notifyTool, MCPTools.showHTMLTool, MCPTools.showTextTool]
    }

    func callTool(_ name: String, id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse? {
        switch name {
        case "notify":
            guard let title = args["title"]?.stringValue,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return JSONRPCResponse(id: id, error: .invalidParams)
            }
            let alert = PadAlert(title: title, body: args["body"]?.stringValue,
                                 host: args["host"]?.stringValue, session: args["session"]?.stringValue,
                                 urgent: args["urgent"]?.boolValue ?? true, at: Date())
            DispatchQueue.main.async { self.agents?.received(alert) }
            return MCPMessageHandler.toolResult(id: id, success: true, message: "Delivered to \(machineName).")
        case "show_html", "show_text":
            guard let title = args["title"]?.stringValue else {
                return JSONRPCResponse(id: id, error: .invalidParams)
            }
            guard let content = args["content"]?.stringValue else {
                // A path names a file on the agent's machine, which this
                // iPad can't read.
                return MCPMessageHandler.toolResult(
                    id: id, success: false,
                    message: "This Onyx is an iPad: it can't read a file by path. Send the text in `content`.")
            }
            let html = name == "show_html" ? content : Self.page(forText: content, title: title)
            DispatchQueue.main.async { self.agents?.received(PadPage(title: title, html: html)) }
            return MCPMessageHandler.toolResult(id: id, success: true, message: "Shown on \(machineName), in a tab.")
        default:
            return nil
        }
    }

    /// Text as a page: monospaced, dark, escaped.
    static func page(forText text: String, title: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>\(escape(title))</title>
        <style>body{background:#000;color:#ddd;margin:16px}pre{font:13px ui-monospace,Menlo,monospace;white-space:pre-wrap}</style>
        </head><body><pre>\(escape(text))</pre></body></html>
        """
    }
}
