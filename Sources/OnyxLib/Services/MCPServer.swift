import Foundation
import Network

// MARK: - JSON-RPC Types

/// JSONRPCRequest.
public struct JSONRPCRequest: Codable {
    /// Jsonrpc.
    public let jsonrpc: String
    /// Id.
    public let id: AnyCodableValue?
    /// Method.
    public let method: String
    /// Params.
    public let params: [String: AnyCodableValue]?

    /// Create a new instance.
    public init(jsonrpc: String = "2.0", id: AnyCodableValue? = nil, method: String, params: [String: AnyCodableValue]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSONRPCResponse.
public struct JSONRPCResponse: Codable {
    /// Jsonrpc.
    public let jsonrpc: String
    /// Id.
    public let id: AnyCodableValue?
    /// Result.
    public let result: AnyCodableValue?
    /// Error.
    public let error: JSONRPCError?

    /// Create a new instance.
    public init(id: AnyCodableValue?, result: AnyCodableValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    /// Create a new instance.
    public init(id: AnyCodableValue?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// JSONRPCError.
public struct JSONRPCError: Codable {
    /// Code.
    public let code: Int
    /// Message.
    public let message: String

    /// Parse error.
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    /// Invalid request.
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    /// Method not found.
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    /// Invalid params.
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
}

/// Type-erased Codable value for JSON-RPC flexibility
public enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    /// Create a new instance.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) } else if let v = try? container.decode(Int.self) { self = .int(v) } else if let v = try? container.decode(Double.self) { self = .double(v) } else if let v = try? container.decode(String.self) { self = .string(v) } else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) } else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) } else if container.decodeNil() { self = .null } else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    /// Encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// String value.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Int value.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        if case .double(let v) = self { return Int(v) }
        return nil
    }

    /// Bool value.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Object value.
    public var objectValue: [String: AnyCodableValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Array value.
    public var arrayValue: [AnyCodableValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

// MARK: - MCP Message Handler

/// MCPMessageHandler.
public class MCPMessageHandler {
    private let artifactManager: ArtifactManager
    private let claudeSessions: ClaudeSessionManager

    /// Create a new instance.
    public init(artifactManager: ArtifactManager, claudeSessions: ClaudeSessionManager) {
        self.artifactManager = artifactManager
        self.claudeSessions = claudeSessions
    }

    /// Handle message.
    public func handleMessage(_ data: Data) -> Data? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
            let response = JSONRPCResponse(id: nil, error: .parseError)
            return try? JSONEncoder().encode(response)
        }
        let response = dispatch(request)
        return try? JSONEncoder().encode(response)
    }

    /// Dispatch.
    public func dispatch(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "notifications/initialized":
            // Client acknowledgment, no response needed for notifications
            return JSONRPCResponse(id: request.id, result: .null)
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
            "serverInfo": .object([
                "name": .string("onyx"),
                "version": .string("1.0.0")
            ])
        ])
        return JSONRPCResponse(id: request.id, result: result)
    }

    // MARK: - Tools List

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let tools: AnyCodableValue = .object([
            "tools": .array([
                showTextTool,
                showDiagramTool,
                showModelTool,
                clearSlotTool,
                listSlotsTool,
                analyzeDepsTool,
            ])
        ])
        return JSONRPCResponse(id: request.id, result: tools)
    }

    private var showTextTool: AnyCodableValue {
        .object([
            "name": .string("show_text"),
            "description": .string("Display text, code, or markdown in an artifact slot. For code files, prefer using the file parameter to load directly — the client renders with syntax highlighting. Line wrapping is auto-detected from file extension (off for code, on for prose) but can be overridden with the wrap parameter."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the artifact")]),
                    "content": .object(["type": .string("string"), "description": .string("Text content to display (optional if file is provided)")]),
                    "file": .object(["type": .string("string"), "description": .string("Absolute path to a file to load and display. The file extension is used for syntax highlighting and wrap detection.")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("plain"), .string("markdown"), .string("html")]), "description": .string("Text format (default: plain for files, markdown for content)")]),
                    "language": .object(["type": .string("string"), "description": .string("Language hint for syntax highlighting (e.g. java, swift, python). Auto-detected from file extension if not specified.")]),
                    "wrap": .object(["type": .string("boolean"), "description": .string("Enable line wrapping. Auto-detected if omitted: off for code, on for markdown/plain prose.")])
                ]),
                "required": .array([.string("slot"), .string("title")])
            ])
        ])
    }

    private var showDiagramTool: AnyCodableValue {
        .object([
            "name": .string("show_diagram"),
            "description": .string("Render a UML or flowchart diagram in an artifact slot visible to the user. Prefer top-down (TD) layouts over left-right (LR) as the display area is a vertical panel. Pinch to zoom is supported."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the diagram")]),
                    "content": .object(["type": .string("string"), "description": .string("Diagram source (Mermaid or PlantUML syntax)")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("mermaid"), .string("plantuml")]), "description": .string("Diagram format (default: mermaid)")])
                ]),
                "required": .array([.string("slot"), .string("title"), .string("content")])
            ])
        ])
    }

    private var showModelTool: AnyCodableValue {
        .object([
            "name": .string("show_model"),
            "description": .string("Display a 3D model in an artifact slot visible to the user"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)]),
                    "title": .object(["type": .string("string"), "description": .string("Title for the model")]),
                    "data": .object(["type": .string("string"), "description": .string("Base64-encoded model data")]),
                    "format": .object(["type": .string("string"), "enum": .array([.string("obj"), .string("usdz"), .string("stl")]), "description": .string("3D model format")])
                ]),
                "required": .array([.string("slot"), .string("title"), .string("data"), .string("format")])
            ])
        ])
    }

    private var clearSlotTool: AnyCodableValue {
        .object([
            "name": .string("clear_slot"),
            "description": .string("Clear an artifact slot"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "slot": .object(["type": .string("integer"), "description": .string("Slot number 0-7"), "minimum": .int(0), "maximum": .int(7)])
                ]),
                "required": .array([.string("slot")])
            ])
        ])
    }

    private var listSlotsTool: AnyCodableValue {
        .object([
            "name": .string("list_slots"),
            "description": .string("List all occupied artifact slots and their contents"),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ])
    }

    private var analyzeDepsTool: AnyCodableValue {
        .object([
            "name": .string("analyze_deps"),
            "description": .string("Analyze the dependency graph between changed Java files in a git repo. Parses imports to find relationships between modified files (including unchanged intermediary files that connect them). Displays result as a Mermaid diagram in artifact slot 0. Requires python3 on the remote host."),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "repo_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the git repository root")
                    ])
                ]),
                "required": .array([.string("repo_path")])
            ])
        ])
    }

    // MARK: - Tool Call Dispatch

    private func handleToolsCall(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: .invalidParams)
        }

        let arguments = params["arguments"]?.objectValue ?? [:]

        switch toolName {
        case "show_text": return callShowText(id: request.id, args: arguments)
        case "show_diagram": return callShowDiagram(id: request.id, args: arguments)
        case "show_model": return callShowModel(id: request.id, args: arguments)
        case "clear_slot": return callClearSlot(id: request.id, args: arguments)
        case "list_slots": return callListSlots(id: request.id)
        case "analyze_deps": return callAnalyzeDeps(id: request.id, args: arguments)
        default:
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32602, message: "Unknown tool: \(toolName)"))
        }
    }

    private static let proseExtensions: Set<String> = ["md", "markdown", "txt", "text", "rst", "adoc", "csv", "log"]

    private static func languageForExtension(_ ext: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "java": "java", "kt": "kotlin", "kts": "kotlin",
            "py": "python", "rb": "ruby", "js": "javascript", "ts": "typescript",
            "tsx": "tsx", "jsx": "jsx", "rs": "rust", "go": "go", "c": "c",
            "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
            "m": "objectivec", "mm": "objectivec", "cs": "csharp",
            "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "fish",
            "json": "json", "xml": "xml", "html": "html", "htm": "html",
            "css": "css", "scss": "scss", "less": "less",
            "sql": "sql", "yaml": "yaml", "yml": "yaml", "toml": "toml",
            "lua": "lua", "r": "r", "scala": "scala", "pl": "perl",
            "php": "php", "ex": "elixir", "exs": "elixir", "erl": "erlang",
            "hs": "haskell", "ml": "ocaml", "clj": "clojure",
            "dart": "dart", "zig": "zig", "nim": "nim",
            "dockerfile": "dockerfile", "makefile": "makefile",
            "gradle": "gradle", "groovy": "groovy",
            "tf": "hcl", "proto": "protobuf", "graphql": "graphql",
            "plist": "xml",
        ]
        return map[ext.lowercased()]
    }

    private func callShowText(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue,
              let title = args["title"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        let content: String
        var fileExtension: String?

        if let filePath = args["file"]?.stringValue {
            // Load file content
            guard let fileData = FileManager.default.contents(atPath: filePath),
                  let fileContent = String(data: fileData, encoding: .utf8) else {
                return toolResult(id: id, success: false, message: "Cannot read file: \(filePath)")
            }
            content = fileContent
            fileExtension = (filePath as NSString).pathExtension
        } else if let textContent = args["content"]?.stringValue {
            content = textContent
        } else {
            return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Either content or file must be provided"))
        }

        // Determine format
        let defaultFormat = fileExtension != nil ? "plain" : "markdown"
        let format = TextFormat(rawValue: args["format"]?.stringValue ?? defaultFormat) ?? .markdown

        // Determine language for syntax highlighting
        let language: String?
        if let lang = args["language"]?.stringValue {
            language = lang
        } else if let ext = fileExtension {
            language = Self.languageForExtension(ext)
        } else {
            language = nil
        }

        // Determine wrap behavior
        let wrap: Bool
        if let wrapVal = args["wrap"]?.boolValue {
            wrap = wrapVal
        } else if let ext = fileExtension {
            wrap = Self.proseExtensions.contains(ext.lowercased())
        } else {
            wrap = format == .markdown || format == .html
        }

        let artifactContent = ArtifactContent.text(content: content, format: format, language: language, wrap: wrap)

        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(slot, title: title, content: artifactContent)
        }
        return toolResult(id: id, success: true, message: "Text displayed in slot \(slot)")
    }

    private func callShowDiagram(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue,
              let title = args["title"]?.stringValue,
              let content = args["content"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }
        let format = DiagramFormat(rawValue: args["format"]?.stringValue ?? "mermaid") ?? .mermaid
        let artifactContent = ArtifactContent.diagram(content: content, format: format)

        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(slot, title: title, content: artifactContent)
        }
        return toolResult(id: id, success: true, message: "Diagram displayed in slot \(slot)")
    }

    private func callShowModel(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue,
              let title = args["title"]?.stringValue,
              let dataStr = args["data"]?.stringValue,
              let formatStr = args["format"]?.stringValue,
              let format = ModelFormat(rawValue: formatStr) else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }
        guard let data = Data(base64Encoded: dataStr) else {
            return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Invalid base64 data"))
        }
        let artifactContent = ArtifactContent.model3D(data: data, format: format)

        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(slot, title: title, content: artifactContent)
        }
        return toolResult(id: id, success: true, message: "3D model displayed in slot \(slot)")
    }

    private func callClearSlot(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.clearSlot(slot)
        }
        return toolResult(id: id, success: true, message: "Slot \(slot) cleared")
    }

    private func callListSlots(id: AnyCodableValue?) -> JSONRPCResponse {
        // Use semaphore with timeout to avoid deadlock if main thread is busy
        var slotsInfo: [(slot: Int, title: String, type: String)] = []
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [self] in
            slotsInfo = self.artifactManager.listSlots()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)

        let slotValues: [AnyCodableValue] = slotsInfo.map { info in
            .object([
                "slot": .int(info.slot),
                "title": .string(info.title),
                "type": .string(info.type)
            ])
        }

        let result: AnyCodableValue = .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(slotsInfo.isEmpty ? "No artifacts displayed" :
                        slotsInfo.map { "Slot \($0.slot): [\($0.type)] \($0.title)" }.joined(separator: "\n"))
                ])
            ]),
            "slots": .array(slotValues)
        ])
        return JSONRPCResponse(id: id, result: result)
    }

    // MARK: - Dependency Analysis

    private func callAnalyzeDeps(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let repoPath = args["repo_path"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        // Write the analysis script to a temp file and run locally.
        // When called via MCP from a remote host, the repo_path is local
        // to that host — but the MCP handler runs in the Onyx app. So this
        // only works for local repos or when the agent calls show_diagram
        // directly with pre-computed Mermaid. For the UI button path, the
        // DependencyAnalyzer handles remote execution via SSH.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-deps-mcp")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let scriptFile = tmpDir.appendingPathComponent("analyze_deps.py")
        try? DependencyAnalyzer.analysisScript.write(to: scriptFile, atomically: true, encoding: .utf8)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptFile.path, repoPath]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return toolResult(id: id, success: false, message: "python3 not available: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let mermaid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if mermaid.isEmpty {
            return toolResult(id: id, success: true, message: "No Java dependency connections found")
        }

        let content = ArtifactContent.diagram(content: mermaid, format: .mermaid)
        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(0, title: "Dependency Graph", content: content)
        }

        return toolResult(id: id, success: true, message: "Dependency graph displayed in artifact slot 0.\n\nMermaid source:\n\(mermaid)")
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

    private func toolResult(id: AnyCodableValue?, success: Bool, message: String) -> JSONRPCResponse {
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

// MARK: - MCP Socket Server

/// MCPSocketServer.
public class MCPSocketServer {
    private var unixListener: NWListener?
    private var tcpListener: NWListener?
    private let handler: MCPMessageHandler
    private let socketPath: String

    /// The TCP port assigned by the OS after the listener starts (loopback only)
    public private(set) var tcpPort: UInt16?

    /// Default remote-side port for SSH -R forwarding
    public static let defaultRemotePort: UInt16 = 19432

    /// Create a new instance.
    public init(artifactManager: ArtifactManager, claudeSessions: ClaudeSessionManager) {
        self.handler = MCPMessageHandler(artifactManager: artifactManager, claudeSessions: claudeSessions)
        // Use ~/.onyx/ for the socket (cross-platform, matches OnyxMCP client)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let onyxDir = home.appendingPathComponent(".onyx")
        try? FileManager.default.createDirectory(at: onyxDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.socketPath = onyxDir.appendingPathComponent("mcp.sock").path
    }

    /// Start.
    public func start() {
        startUnixSocket()
        startTCPListener()
    }

    private func startUnixSocket() {
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
        unlink(socketPath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
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
            if !isComplete && error == nil {
                self.receiveMessage(on: connection)
            }
        }
    }
}
