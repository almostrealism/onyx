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
            case .text(let content, let format, let language, let wrap):
                TextArtifactView(content: content, format: format, language: language, wrap: wrap)
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
    let language: String?
    let wrap: Bool

    var body: some View {
        CodeWebView(content: content, format: format, language: language, wrap: wrap)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CodeWebView: NSViewRepresentable {
    let content: String
    let format: TextFormat
    let language: String?
    let wrap: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        loadContent(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadContent(webView)
    }

    private func loadContent(_ webView: WKWebView) {
        let escaped = content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let wrapCSS = wrap
            ? "white-space: pre-wrap; word-wrap: break-word;"
            : "white-space: pre; overflow-x: auto;"

        let langClass = language.map { "language-\($0)" } ?? "nohighlight"

        let html: String
        switch format {
        case .markdown:
            html = markdownHTML(escaped, wrapCSS: wrapCSS)
        default:
            html = codeHTML(escaped, langClass: langClass, wrapCSS: wrapCSS)
        }

        webView.loadHTMLString(html, baseURL: nil)
    }

    private func codeHTML(_ escaped: String, langClass: String, wrapCSS: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css">
        <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #0f0f0f;
                font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
                font-size: 12px;
                line-height: 1.5;
                color: #d4d4d4;
            }
            pre {
                margin: 0;
                padding: 12px;
                \(wrapCSS)
            }
            code {
                font-family: inherit;
                font-size: inherit;
                \(wrapCSS)
            }
            .hljs {
                background: #0f0f0f !important;
                padding: 12px !important;
            }
            /* Line numbers */
            .line-numbers {
                counter-reset: line;
            }
            .line-numbers .line::before {
                counter-increment: line;
                content: counter(line);
                display: inline-block;
                width: 3em;
                margin-right: 1em;
                text-align: right;
                color: #555;
                -webkit-user-select: none;
                user-select: none;
            }
        </style>
        </head><body>
        <pre><code class="\(langClass)">\(escaped)</code></pre>
        <script>
            document.querySelectorAll('pre code:not(.nohighlight)').forEach(el => hljs.highlightElement(el));
        </script>
        </body></html>
        """
    }

    private func markdownHTML(_ escaped: String, wrapCSS: String) -> String {
        """
        <!DOCTYPE html>
        <html><head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css">
        <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/marked@14/marked.min.js"></script>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                background: #0f0f0f;
                font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #d4d4d4;
                padding: 12px;
                \(wrapCSS)
            }
            h1, h2, h3, h4, h5, h6 { color: #e0e0e0; margin: 0.8em 0 0.4em; }
            h1 { font-size: 1.4em; }
            h2 { font-size: 1.2em; }
            h3 { font-size: 1.1em; }
            a { color: #58a6ff; }
            code {
                font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
                font-size: 0.9em;
                background: #1a1a1a;
                padding: 2px 5px;
                border-radius: 3px;
            }
            pre {
                background: #1a1a1a;
                border-radius: 6px;
                padding: 12px;
                margin: 0.6em 0;
                overflow-x: auto;
            }
            pre code {
                background: none;
                padding: 0;
                font-size: 12px;
                line-height: 1.5;
            }
            .hljs { background: #1a1a1a !important; }
            blockquote {
                border-left: 3px solid #444;
                padding-left: 12px;
                color: #999;
                margin: 0.6em 0;
            }
            ul, ol { padding-left: 1.5em; margin: 0.4em 0; }
            li { margin: 0.2em 0; }
            table { border-collapse: collapse; margin: 0.6em 0; }
            th, td { border: 1px solid #333; padding: 6px 10px; }
            th { background: #1a1a1a; }
            hr { border: none; border-top: 1px solid #333; margin: 1em 0; }
            img { max-width: 100%; }
        </style>
        </head><body>
        <div id="content"></div>
        <script>
            const raw = \(jsStringLiteral(content));
            marked.setOptions({
                highlight: function(code, lang) {
                    if (lang && hljs.getLanguage(lang)) {
                        return hljs.highlight(code, { language: lang }).value;
                    }
                    return hljs.highlightAuto(code).value;
                },
                breaks: true,
                gfm: true
            });
            document.getElementById('content').innerHTML = marked.parse(raw);
        </script>
        </body></html>
        """
    }

    private func jsStringLiteral(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return "`\(escaped)`"
    }
}

// MARK: - Diagram Artifact

private struct DiagramArtifactView: View {
    let content: String
    let format: DiagramFormat
    let accentColor: Color
    @State private var zoomLevel: Double = 1.0
    @State private var webViewRef: WKWebView?

    private let zoomPresets: [(String, Double)] = [
        ("Fit", 1.0),
        ("100%", 1.0),
        ("200%", 2.0),
        ("300%", 3.0),
        ("500%", 5.0),
        ("750%", 7.5),
        ("1000%", 10.0),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MermaidWebView(source: content, format: format, zoom: $zoomLevel, webViewRef: $webViewRef)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Zoom controls
            VStack(spacing: 4) {
                // Zoom preset menu
                Menu {
                    ForEach(zoomPresets, id: \.1) { name, level in
                        Button(name) {
                            zoomLevel = level
                            webViewRef?.magnification = level
                        }
                    }
                } label: {
                    Text("\(Int(zoomLevel * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 50)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 50)

                HStack(spacing: 2) {
                    Button(action: {
                        zoomLevel = max(0.25, zoomLevel / 1.5)
                        webViewRef?.magnification = zoomLevel
                    }) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        zoomLevel = min(10.0, zoomLevel * 1.5)
                        webViewRef?.magnification = zoomLevel
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        zoomLevel = 1.0
                        webViewRef?.magnification = 1.0
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundColor(.white.opacity(0.7))
            .padding(8)
            .background(Color.black.opacity(0.7))
            .cornerRadius(6)
            .padding(12)
        }
    }
}

struct MermaidWebView: NSViewRepresentable {
    let source: String
    let format: DiagramFormat
    @Binding var zoom: Double
    @Binding var webViewRef: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.magnification = zoom
        loadDiagram(webView)
        DispatchQueue.main.async { webViewRef = webView }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if source changed, not on zoom changes
        if context.coordinator.lastSource != source {
            context.coordinator.lastSource = source
            loadDiagram(webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    class Coordinator {
        var lastSource: String
        init(source: String) { self.lastSource = source }
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
