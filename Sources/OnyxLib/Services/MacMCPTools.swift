//
// MacMCPTools.swift
//
// Responsibility: The MCP tools only the Mac has — the artifact slots
//                 (text, HTML, diagrams, models), the dependency graph, and
//                 alerts with the Mac's delivery (the menu bar, Notification
//                 Center, the forwarder). The protocol and the shared tools
//                 are OnyxCore's MCPMessageHandler.
//

import Foundation
import OnyxCore

public final class MacMCPTools: MCPToolHost {
    private let artifactManager: ArtifactManager

    public init(artifactManager: ArtifactManager) {
        self.artifactManager = artifactManager
    }

    public var machineName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    public var toolDefinitions: [AnyCodableValue] {
        [MCPTools.showTextTool, MCPTools.showDiagramTool, MCPTools.showModelTool,
         MCPTools.clearSlotTool, MCPTools.listSlotsTool, MCPTools.analyzeDepsTool,
         MCPTools.notifyTool, MCPTools.showHTMLTool]
    }

    public func callTool(_ name: String, id: AnyCodableValue?,
                         args arguments: [String: AnyCodableValue]) -> JSONRPCResponse? {
        switch name {
        case "show_text": return callShowText(id: id, args: arguments)
        case "show_diagram": return callShowDiagram(id: id, args: arguments)
        case "show_model": return callShowModel(id: id, args: arguments)
        case "clear_slot": return callClearSlot(id: id, args: arguments)
        case "list_slots": return callListSlots(id: id)
        case "analyze_deps": return callAnalyzeDeps(id: id, args: arguments)
        case "notify": return callNotify(id: id, args: arguments)
        case "show_html": return callShowHTML(id: id, args: arguments)
        default: return nil
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

    private func callShowHTML(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue,
              let title = args["title"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        let html: String
        if let path = args["file"]?.stringValue {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                // Name the likely cause: this is the mistake a remote
                // agent makes, and "cannot read file" alone sends it
                // looking at permissions on the wrong machine.
                return MCPMessageHandler.toolResult(id: id, success: false,
                                  message: "Cannot read \(path) — note that Onyx reads files "
                                         + "on the machine it runs on. If you are on a remote "
                                         + "host, read the file there and pass `content`.")
            }
            html = text
        } else if let content = args["content"]?.stringValue {
            html = content
        } else {
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32602, message: "Either content or file must be provided"))
        }

        let artifactContent = ArtifactContent.text(content: html, format: .html,
                                                    language: nil, wrap: true)
        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(slot, title: title, content: artifactContent)
        }
        return MCPMessageHandler.toolResult(id: id, success: true, message: "Showing in slot \(slot).")
    }

    private func callNotify(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let title = args["title"]?.stringValue,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        // `queued_at` is added by the bridge when replaying an alert it
        // couldn't deliver at the time. Only trust it to move an alert
        // BACKWARDS: a clock-skewed host claiming the future would sort
        // itself above everything real.
        let sentAt: Date = {
            guard let seconds = args["queued_at"]?.doubleValue else { return Date() }
            let claimed = Date(timeIntervalSince1970: seconds)
            return claimed < Date() ? claimed : Date()
        }()

        let outcome = AlertDelivery.shared.deliver(
            title: title,
            body: args["body"]?.stringValue,
            // Urgent unless the agent says otherwise. `external`, if an older
            // guide still sends it, is accepted and ignored: where an alert
            // goes is the user's setting, not the caller's.
            urgent: args["urgent"]?.boolValue ?? true,
            user: args["user"]?.stringValue,
            host: args["host"]?.stringValue,
            session: args["session"]?.stringValue,
            at: sentAt)

        // Tell the agent where it landed. "Delivered" when it named no
        // session; when it named one that matched nothing, say so — an
        // agent that can see its aim missed can ask the user rather than
        // repeating the same miss.
        switch outcome.matchedTarget {
        case .none:
            return MCPMessageHandler.toolResult(id: id, success: true, message: "Delivered.")
        case .some(true):
            // Worth saying when the user didn't match: the alert landed
            // correctly, but the agent's idea of who it is is wrong, and
            // an agent told this can stop sending a user that never helps.
            let where_ = outcome.ignoredUser
                ? "Delivered, shown against that session — matched on host/session; "
                  + "the user you named isn't the one Onyx connects as (a `su` or `sudo -u` "
                  + "away, most likely), so it was ignored."
                : "Delivered, shown against that session."
            return MCPMessageHandler.toolResult(id: id, success: true, message: where_)
        case .some(false):
            return MCPMessageHandler.toolResult(id: id, success: true,
                              message: "Delivered, but no session matched that user/host/session "
                                     + "— it is in the general alert list. Check the values, or "
                                     + "ask the user which session they see this work in.")
        }
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
                return MCPMessageHandler.toolResult(id: id, success: false, message: "Cannot read file: \(filePath)")
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
        return MCPMessageHandler.toolResult(id: id, success: true, message: "Text displayed in slot \(slot)")
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
        return MCPMessageHandler.toolResult(id: id, success: true, message: "Diagram displayed in slot \(slot)")
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
        return MCPMessageHandler.toolResult(id: id, success: true, message: "3D model displayed in slot \(slot)")
    }

    private func callClearSlot(id: AnyCodableValue?, args: [String: AnyCodableValue]) -> JSONRPCResponse {
        guard let slot = args["slot"]?.intValue else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }

        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.clearSlot(slot)
        }
        return MCPMessageHandler.toolResult(id: id, success: true, message: "Slot \(slot) cleared")
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
            return MCPMessageHandler.toolResult(id: id, success: false, message: "python3 not available: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let mermaid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if mermaid.isEmpty {
            return MCPMessageHandler.toolResult(id: id, success: true, message: "No Java dependency connections found")
        }

        let content = ArtifactContent.diagram(content: mermaid, format: .mermaid)
        DispatchQueue.main.async { [self] in
            _ = self.artifactManager.setSlot(0, title: "Dependency Graph", content: content)
        }

        return MCPMessageHandler.toolResult(id: id, success: true, message: "Dependency graph displayed in artifact slot 0.\n\nMermaid source:\n\(mermaid)")
    }
}

extension MCPMessageHandler {
    /// The Mac's handler: its own tools, the app's Claude sessions.
    public convenience init(artifactManager: ArtifactManager, claudeSessions: ClaudeSessionManager) {
        self.init(tools: MacMCPTools(artifactManager: artifactManager), claudeSessions: claudeSessions)
    }
}
