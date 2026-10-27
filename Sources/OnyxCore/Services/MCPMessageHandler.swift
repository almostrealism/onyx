//
// MCPMessageHandler.swift
//
// Responsibility: Answering MCP — newline-delimited JSON-RPC from the
//                 OnyxMCP bridge on a host — for whichever Onyx is running:
//                 the protocol, the shared tools, and Claude Code's hook
//                 events. What else an Onyx offers is its MCPToolHost.
// Scope: Service.
//

import Foundation
import OnyxVersion

/// The tools one kind of Onyx offers on top of the ones every Onyx has
/// (`onyx_guide`, `onyx_status`): the Mac's artifacts and alerts, the
/// iPad's alerts and pages.
public protocol MCPToolHost: AnyObject {
    /// Listed after the shared ones' definitions, from `MCPTools`.
    var toolDefinitions: [AnyCodableValue] { get }
    /// Run `name`, or nil when this host has no such tool.
    func callTool(_ name: String, id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse?
    /// "mac-studio", "Michael's iPad": who answered, for `OnyxMCP --status`.
    var machineName: String { get }
}

public class MCPMessageHandler {
    private let tools: MCPToolHost
    private let claudeSessions: ClaudeSessionManager

    /// Create a new instance.
    public init(tools: MCPToolHost, claudeSessions: ClaudeSessionManager) {
        self.tools = tools
        self.claudeSessions = claudeSessions
    }

    /// Handle message. Returns nil when nothing may be sent back.
    ///
    /// A JSON-RPC message with no id is a NOTIFICATION, and answering one
    /// is a protocol violation — the reply has no id to carry, so it goes
    /// out as `{"result":null}`, which is not a valid response object.
    /// Claude Code validates what it receives and rejects that; the visible
    /// symptom is "Failed to reconnect to onyx" with the detail buried in
    /// its MCP log, because the connection is dropped on the invalid
    /// message rather than on anything that actually went wrong.
    ///
    /// The one that bites in practice is `notifications/cancelled`, which
    /// the client sends whenever the user interrupts — so the server would
    /// answer it, get dropped, and the fault would look like it belonged
    /// to whatever ran next.
    public func handleMessage(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
            // A parse error is the one case the spec DOES want a null id:
            // there was no readable id to echo.
            let response = JSONRPCResponse(id: nil, error: .parseError)
            return try? JSONEncoder().encode(response)
        }
        guard !Self.isNotification(request) else {
            dispatchNotification(request)
            return nil
        }
        let response = dispatch(request)
        return try? JSONEncoder().encode(response)
    }

    /// No id, or an explicit JSON null, means "don't answer this".
    static func isNotification(_ request: JSONRPCRequest) -> Bool {
        switch request.id {
        case .none, .some(.null): return true
        default:                  return false
        }
    }

    /// Side effects for the notifications we care about. Most are pure
    /// acknowledgments with nothing to do — but a notification we don't
    /// recognize must still produce NO reply, which is why this is not
    /// routed through `dispatch`: that one answers unknown methods with
    /// methodNotFound, and an unanswerable request can't be told off.
    private func dispatchNotification(_ request: JSONRPCRequest) {
        switch request.method {
        case "notifications/initialized", "notifications/cancelled":
            break
        default:
            break
        }
    }

    /// Dispatch.
    public func dispatch(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "ping":
            // Liveness. An empty result is the whole answer; methodNotFound
            // here reads to a client as a server that can't be trusted.
            return JSONRPCResponse(id: request.id, result: .object([:]))
        case "notifications/initialized":
            // Only reachable if a client sends this WITH an id, which is
            // malformed but harmless to humor.
            return JSONRPCResponse(id: request.id, result: .object([:]))
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return handleToolsCall(request)
        case "claude/hook":
            return handleClaudeHook(request)
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound)
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: AnyCodableValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            // The bridge records who answered, so `OnyxMCP --status` on a
            // host can say "mac-studio, Onyx 0.17, last answered 2 min
            // ago" rather than "something spoke JSON-RPC once". Version
            // was a hardcoded "1.0.0" before, which told nobody anything.
            "serverInfo": .object([
                "name": .string("onyx"),
                "version": .string(OnyxVersion.current),
                "machine": .string(tools.machineName),
                "proto": .int(OnyxVersion.bridgeProtocol)
            ])
        ])
        return JSONRPCResponse(id: request.id, result: result)
    }

    // MARK: - Tools List

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let tools: AnyCodableValue = .object([
            "tools": .array(tools.toolDefinitions + [MCPTools.guideTool, MCPTools.statusTool])
        ])
        return JSONRPCResponse(id: request.id, result: tools)
    }

    private func handleToolsCall(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: .invalidParams)
        }

        let arguments = params["arguments"]?.objectValue ?? [:]

        switch toolName {
        case "onyx_guide":
            return Self.toolResult(id: request.id, success: true,
                                   message: OnyxGuide.response(for: arguments["topic"]?.stringValue))
        case "onyx_status":
            // Reaching here at all is the diagnosis.
            return Self.toolResult(id: request.id, success: true,
                                   message: "The Onyx desktop answered this directly — it is reachable "
                                          + "from here. (\(tools.machineName), Onyx \(OnyxVersion.current).)")
        default:
            if let answer = tools.callTool(toolName, id: request.id, args: arguments) { return answer }
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)"))
        }
    }

    // MARK: - Claude Hook Handler

    /// Handle a claude/hook event from OnyxMCP --hook mode.
    /// The params contain the raw hook event JSON from Claude Code.
    /// For PermissionRequest events, this BLOCKS until the user responds in the UI.
    private func handleClaudeHook(_ request: JSONRPCRequest) -> JSONRPCResponse {
        // Convert AnyCodableValue params to [String: Any] for the session manager
        guard let params = request.params else {
            return JSONRPCResponse(id: request.id, error: .invalidParams)
        }

        let event = codableToDict(params)
        // Process on a background thread since PermissionRequest may block
        let result = claudeSessions.processHookEvent(event)

        // Convert result back to AnyCodableValue
        let resultValue = dictToCodable(result)
        return JSONRPCResponse(id: request.id, result: resultValue)
    }

    private func codableToDict(_ params: [String: AnyCodableValue]) -> [String: Any] {
        var dict: [String: Any] = [:]
        for (key, value) in params {
            dict[key] = codableValueToAny(value)
        }
        return dict
    }

    private func codableValueToAny(_ value: AnyCodableValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { codableValueToAny($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = codableValueToAny(v) }
            return dict
        }
    }

    private func dictToCodable(_ dict: [String: Any]) -> AnyCodableValue {
        var obj: [String: AnyCodableValue] = [:]
        for (key, value) in dict {
            obj[key] = anyToCodableValue(value)
        }
        return .object(obj)
    }

    private func anyToCodableValue(_ value: Any) -> AnyCodableValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map { anyToCodableValue($0) })
        case let dict as [String: Any]: return dictToCodable(dict)
        default: return .null
        }
    }

    /// A tool's answer: one text block, flagged as an error when it failed.
    public static func toolResult(id: AnyCodableValue?, success: Bool, message: String) -> JSONRPCResponse {
        let result: AnyCodableValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(message)
                ])
            ]),
            "isError": .bool(!success)
        ])
        return JSONRPCResponse(id: id, result: result)
    }
}
