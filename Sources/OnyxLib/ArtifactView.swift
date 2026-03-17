import SwiftUI
import WebKit
import SceneKit

// MARK: - Artifact Panel

struct ArtifactView: View {
    @ObservedObject var appState: AppState

    private var manager: ArtifactManager { appState.artifactManager }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ARTIFACTS")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                Spacer()

                if manager.hasArtifacts {
                    Button(action: { manager.clearAll() }) {
                        Text("Clear All")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { appState.activeRightPanel = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().background(Color.white.opacity(0.1))

            if manager.hasArtifacts {
                // Slot tabs
                SlotTabBar(manager: manager, accentColor: appState.accentColor)

                Divider().background(Color.white.opacity(0.1))

                // Active slot content
                if let artifact = manager.slots[manager.activeSlot] {
                    ArtifactContentView(artifact: artifact, accentColor: appState.accentColor)
                } else {
                    emptySlotView
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 28))
                        .foregroundColor(.gray.opacity(0.3))
                    Text("No artifacts")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                    Text("Artifacts appear here when a coding\nagent uses the Onyx MCP tools")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.25))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
        }
        .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))
    }

    private var emptySlotView: some View {
        VStack {
            Spacer()
            Text("Empty slot")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
            Spacer()
        }
    }
}

// MARK: - Slot Tab Bar

private struct SlotTabBar: View {
    @ObservedObject var manager: ArtifactManager
    let accentColor: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(manager.slots.keys.sorted()), id: \.self) { slot in
                    let artifact = manager.slots[slot]!
                    let isActive = manager.activeSlot == slot

                    Button(action: { manager.activeSlot = slot }) {
                        HStack(spacing: 4) {
                            Text("\(slot)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(isActive ? accentColor : .gray.opacity(0.4))

                            Image(systemName: iconForType(artifact.content))
                                .font(.system(size: 9))
                                .foregroundColor(isActive ? accentColor : .gray.opacity(0.4))

                            Text(artifact.title)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(isActive ? .white : .gray.opacity(0.5))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isActive ? accentColor.opacity(0.15) : Color.white.opacity(0.04))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func iconForType(_ content: ArtifactContent) -> String {
        switch content {
        case .text: return "doc.text"
        case .diagram: return "chart.dots.scatter"
        case .model3D: return "cube"
        }
    }
}

// MARK: - Artifact Content View

private struct ArtifactContentView: View {
    let artifact: Artifact
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text(artifact.title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(artifact.content.typeLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))

            // Content
            switch artifact.content {
            case .text(let content, let format):
                TextArtifactView(content: content, format: format)
            case .diagram(let content, let format):
                DiagramArtifactView(content: content, format: format, accentColor: accentColor)
            case .model3D(let data, let format):
                ModelArtifactView(data: data, format: format)
            }
        }
    }
}

// MARK: - Text Artifact

private struct TextArtifactView: View {
    let content: String
    let format: TextFormat

    var body: some View {
        ScrollView {
            switch format {
            case .plain:
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            case .markdown:
                Text(markdownAttributed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            case .html:
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var markdownAttributed: AttributedString {
        (try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(content)
    }
}

// MARK: - Diagram Artifact

private struct DiagramArtifactView: View {
    let content: String
    let format: DiagramFormat
    let accentColor: Color

    var body: some View {
        MermaidWebView(source: content, format: format)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MermaidWebView: NSViewRepresentable {
    let source: String
    let format: DiagramFormat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.magnification = 1.0
        loadDiagram(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadDiagram(webView)
    }

    private func loadDiagram(_ webView: WKWebView) {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let html: String
        switch format {
        case .mermaid:
            html = """
            <!DOCTYPE html>
            <html><head>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
            <style>
                body { background: #0f0f0f; margin: 0; padding: 16px; display: flex; justify-content: center; align-items: start; overflow: auto; }
                .mermaid { color: #ccc; }
                .mermaid svg { max-width: none !important; }
            </style>
            </head><body>
            <pre class="mermaid">\(escaped)</pre>
            <script>mermaid.initialize({ startOnLoad: true, theme: 'dark', maxTextSize: 100000 });</script>
            </body></html>
            """
        case .plantuml:
            // Encode PlantUML and use the online renderer
            let encoded = plantumlEncode(source)
            html = """
            <!DOCTYPE html>
            <html><head>
            <style>
                body { background: #0f0f0f; margin: 0; padding: 16px; display: flex; justify-content: center; align-items: center; height: 100vh; }
                img { max-width: 100%; max-height: 100%; }
            </style>
            </head><body>
            <img src="https://www.plantuml.com/plantuml/svg/\(encoded)" />
            </body></html>
            """
        }

        webView.loadHTMLString(html, baseURL: nil)
    }

    /// PlantUML text encoding for URL
    private func plantumlEncode(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        let compressed = (try? (data as NSData).compressed(using: .zlib)) ?? data as NSData
        return (compressed as Data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 3D Model Artifact

private struct ModelArtifactView: View {
    let data: Data
    let format: ModelFormat

    var body: some View {
        SceneKitView(data: data, format: format)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SceneKitView: NSViewRepresentable {
    let data: Data
    let format: ModelFormat

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = NSColor(white: 0.06, alpha: 1.0)
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X

        loadScene(into: scnView)
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        loadScene(into: scnView)
    }

    private func loadScene(into scnView: SCNView) {
        let tempDir = FileManager.default.temporaryDirectory
        let ext: String
        switch format {
        case .obj: ext = "obj"
        case .usdz: ext = "usdz"
        case .stl: ext = "stl"
        }
        let tempFile = tempDir.appendingPathComponent("onyx_model.\(ext)")

        do {
            try data.write(to: tempFile)
            let scene = try SCNScene(url: tempFile, options: [
                .checkConsistency: true
            ])
            scnView.scene = scene

            // Add ambient light
            let ambientLight = SCNNode()
            ambientLight.light = SCNLight()
            ambientLight.light?.type = .ambient
            ambientLight.light?.color = NSColor(white: 0.4, alpha: 1.0)
            scene.rootNode.addChildNode(ambientLight)
        } catch {
            // Show error in scene
            let scene = SCNScene()
            let textGeometry = SCNText(string: "Failed to load model", extrusionDepth: 0.1)
            textGeometry.font = NSFont.monospacedSystemFont(ofSize: 0.5, weight: .regular)
            textGeometry.firstMaterial?.diffuse.contents = NSColor.gray
            let textNode = SCNNode(geometry: textGeometry)
            scene.rootNode.addChildNode(textNode)
            scnView.scene = scene
        }
    }
}
