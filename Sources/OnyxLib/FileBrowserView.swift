import SwiftUI
import UniformTypeIdentifiers
import Combine

public struct RemoteEntry: Identifiable, Comparable {
    public let id = UUID()
    public let name: String
    public let isDirectory: Bool
    public let size: String
    public let modified: String

    public init(name: String, isDirectory: Bool, size: String, modified: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public static func < (lhs: RemoteEntry, rhs: RemoteEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

public class FileBrowserManager: ObservableObject {
    @Published public var savedFolders: [String] = []
    @Published public var currentPath: String?
    @Published public var entries: [RemoteEntry] = []
    @Published public var fileContent: String?
    @Published public var viewingFileName: String?
    @Published public var isLoading = false
    @Published public var error: String?
    @Published public var showAddFolder = false
    @Published public var pathHistory: [String] = []

    private let appState: AppState
    private var gitCancellable: AnyCancellable?

    public lazy var gitManager: GitManager = {
        let g = GitManager(appState: appState)
        gitCancellable = g.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return g
    }()

    public init(appState: AppState) {
        self.appState = appState
        loadSavedFolders()
    }

    // MARK: - Persistence

    private func loadSavedFolders() {
        guard let data = try? Data(contentsOf: appState.savedFoldersURL),
              let folders = try? JSONDecoder().decode([String].self, from: data) else { return }
        savedFolders = folders
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(savedFolders) {
            try? data.write(to: appState.savedFoldersURL)
        }
    }

    public func addFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savedFolders.contains(trimmed) else { return }
        savedFolders.append(trimmed)
        saveFolders()
    }

    public func removeFolder(_ path: String) {
        savedFolders.removeAll { $0 == path }
        saveFolders()
        if currentPath?.hasPrefix(path) == true {
            currentPath = nil
            entries = []
            fileContent = nil
            gitManager.clear()
        }
    }

    // MARK: - Navigation

    public func navigateTo(_ path: String) {
        fileContent = nil
        viewingFileName = nil
        if let current = currentPath {
            pathHistory.append(current)
        }
        currentPath = path
        listDirectory(path)
        gitManager.checkAndLoad(path: path)
    }

    public func navigateBack() {
        fileContent = nil
        viewingFileName = nil
        if let prev = pathHistory.popLast() {
            currentPath = prev
            listDirectory(prev)
            gitManager.checkAndLoad(path: prev)
        } else {
            currentPath = nil
            entries = []
            gitManager.clear()
        }
    }

    public func openEntry(_ entry: RemoteEntry) {
        guard let current = currentPath else { return }
        let fullPath = current.hasSuffix("/") ? "\(current)\(entry.name)" : "\(current)/\(entry.name)"
        if entry.isDirectory {
            navigateTo(fullPath)
        } else {
            readFile(fullPath, name: entry.name)
        }
    }

    public func closeFile() {
        fileContent = nil
        viewingFileName = nil
    }

    // MARK: - Remote Operations

    private func listDirectory(_ path: String) {
        isLoading = true
        error = nil
        entries = []

        // ls -lA with a marker to distinguish dirs: append / to dirs
        let escaped = escapeForShell(path)
        let script = "ls -lAp \(escaped) 2>&1"
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProcessWithStatus(cmd: cmd, args: args)
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let self = self else { return }
                if let output = result.output {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                    // Detect SSH connection/auth failures (exit code 255 is SSH error)
                    if result.exitCode == 255 || trimmed.contains("Permission denied (publickey") {
                        let host = self.appState.activeHost?.label ?? "remote host"
                        self.error = "Cannot connect to \(host).\nOpen a terminal session to this host first."
                    } else if trimmed.contains("No such file or directory")
                        || trimmed.contains("Permission denied")
                        || trimmed.contains("not a directory")
                        || trimmed.hasPrefix("ls:") {
                        self.error = trimmed
                    } else {
                        self.entries = self.parseLsOutput(output)
                        if self.entries.isEmpty && !trimmed.isEmpty && !trimmed.hasPrefix("total") {
                            self.error = trimmed
                        }
                    }
                } else {
                    self.error = "Failed to list directory"
                }
            }
        }
    }

    private func readFile(_ path: String, name: String) {
        isLoading = true
        error = nil

        // Read first 2000 lines to avoid huge files
        let escaped = escapeForShell(path)
        let script = "head -2000 \(escaped) 2>&1"
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProcessWithStatus(cmd: cmd, args: args)
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let self = self else { return }
                if result.exitCode == 255 {
                    let host = self.appState.activeHost?.label ?? "remote host"
                    self.error = "Cannot connect to \(host).\nOpen a terminal session to this host first."
                } else if let output = result.output {
                    self.fileContent = output
                    self.viewingFileName = name
                } else {
                    self.error = "Failed to read file"
                }
            }
        }
    }

    struct ProcessResult {
        let output: String?
        let exitCode: Int32
    }

    static func runProcess(cmd: String, args: [String]) -> String? {
        let result = runProcessWithStatus(cmd: cmd, args: args)
        return result.output
    }

    static func runProcessWithStatus(cmd: String, args: [String]) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 10)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()

            process.waitUntilExit()
            killTimer.cancel()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return ProcessResult(output: output, exitCode: process.terminationStatus)
        } catch {
            return ProcessResult(output: nil, exitCode: -1)
        }
    }

    public func parseLsOutput(_ output: String) -> [RemoteEntry] {
        var results: [RemoteEntry] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip the "total" line and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("total ") { continue }

            // Parse ls -lAp output: permissions links owner group size month day time/year name
            let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            let name = String(parts[8])
            // Skip . and ..
            if name == "./" || name == "../" || name == "." || name == ".." { continue }

            let isDir = name.hasSuffix("/")
            let displayName = isDir ? String(name.dropLast()) : name
            let size = String(parts[4])
            let modified = "\(parts[5]) \(parts[6]) \(parts[7])"

            results.append(RemoteEntry(name: displayName, isDirectory: isDir, size: size, modified: modified))
        }
        return results.sorted()
    }

    // MARK: - Upload

    @Published public var uploadStatus: String?
    @Published public var isUploading = false

    public func uploadFiles(_ urls: [URL]) {
        guard let dest = currentPath else { return }
        isUploading = true
        uploadStatus = "Uploading \(urls.count) item\(urls.count == 1 ? "" : "s")..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var errors: [String] = []

            for (i, url) in urls.enumerated() {
                DispatchQueue.main.async {
                    self.uploadStatus = "Uploading (\(i + 1)/\(urls.count)): \(url.lastPathComponent)"
                }

                let success: Bool
                if self.appState.activeHost?.isLocal ?? true {
                    success = self.copyLocal(url, toDir: dest)
                } else {
                    success = self.scpUpload(url, toDir: dest)
                }
                if !success {
                    errors.append(url.lastPathComponent)
                }
            }

            DispatchQueue.main.async {
                self.isUploading = false
                if errors.isEmpty {
                    self.uploadStatus = "Upload complete"
                } else {
                    self.uploadStatus = "Failed: \(errors.joined(separator: ", "))"
                }
                // Refresh directory listing
                self.listDirectory(dest)
                // Clear status after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.uploadStatus?.hasPrefix("Upload") == true || self.uploadStatus?.hasPrefix("Failed") == true {
                        self.uploadStatus = nil
                    }
                }
            }
        }
    }

    private func copyLocal(_ url: URL, toDir dest: String) -> Bool {
        let destPath = (dest as NSString).appendingPathComponent(url.lastPathComponent)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-R", url.path, destPath]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func scpUpload(_ url: URL, toDir dest: String) -> Bool {
        let ssh = appState.activeSSHConfig
        var args = [String]()
        args.append("-r")  // recursive for directories
        args.append("-o"); args.append("BatchMode=yes")
        args.append("-o"); args.append("ConnectTimeout=10")
        args.append("-o"); args.append("StrictHostKeyChecking=accept-new")
        if ssh.port != 22 {
            args.append("-P"); args.append("\(ssh.port)")
        }
        if !ssh.identityFile.isEmpty {
            args.append("-i"); args.append(ssh.identityFile)
        }
        args.append(url.path)
        let userHost = ssh.user.isEmpty ? ssh.host : "\(ssh.user)@\(ssh.host)"
        args.append("\(userHost):\(dest)/")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Escape a path for safe use inside a double-quoted shell string
    public func escapeForShell(_ s: String) -> String {
        // Wrap in double quotes, escaping the chars that are special inside double quotes
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}

// MARK: - Views

struct FileBrowserView: View {
    @ObservedObject var appState: AppState
    @StateObject private var browser: FileBrowserManager
    @State private var isDragOver = false

    init(appState: AppState) {
        self.appState = appState
        _browser = StateObject(wrappedValue: FileBrowserManager(appState: appState))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar: saved folders
            FolderSidebar(appState: appState, browser: browser)
                .frame(width: 220)

            Divider().background(Color.white.opacity(0.1))

            // Main content
            ZStack {
                VStack(spacing: 0) {
                    // Breadcrumb / navigation bar
                    NavigationBar(appState: appState, browser: browser)

                    Divider().background(Color.white.opacity(0.1))

                    // Content area
                    if browser.isLoading && !browser.isUploading {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7).colorScheme(.dark)
                            Text("Loading...")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.5))
                        }
                        Spacer()
                    } else if let error = browser.error {
                        Spacer()
                        Text(error)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(hex: "FF6B6B").opacity(0.8))
                        Spacer()
                    } else if let content = browser.fileContent {
                        FileContentView(
                            fileName: browser.viewingFileName ?? "file",
                            content: content,
                            accentColor: appState.accentColor,
                            onClose: { browser.closeFile() }
                        )
                    } else if browser.currentPath != nil {
                        VStack(spacing: 0) {
                            if browser.gitManager.isGitRepo, let status = browser.gitManager.repoStatus {
                                GitLandingView(status: status, accentColor: appState.accentColor)
                                Divider().background(Color.white.opacity(0.1))
                            }
                            DirectoryListView(appState: appState, browser: browser)
                        }
                    } else {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 28))
                                .foregroundColor(.gray.opacity(0.3))
                            Text("Select a folder to browse")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("⌘O to toggle  ·  Add folders with +")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.3))
                        }
                        Spacer()
                    }

                    // Upload status bar
                    if let status = browser.uploadStatus {
                        HStack(spacing: 8) {
                            if browser.isUploading {
                                ProgressView().scaleEffect(0.6).colorScheme(.dark)
                            } else if status.hasPrefix("Failed") {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "FF6B6B"))
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "6BFF8E"))
                            }
                            Text(status)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.05))
                    }
                }

                // Drop zone overlay
                if isDragOver && browser.currentPath != nil {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(appState.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .background(appState.accentColor.opacity(0.08))
                        .cornerRadius(8)
                        .padding(8)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 32))
                                    .foregroundColor(appState.accentColor)
                                Text("Drop to upload")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(appState.accentColor)
                            }
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                guard browser.currentPath != nil else { return false }
                handleDrop(providers)
                return true
            }
        }
        .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                browser.uploadFiles(urls)
            }
        }
    }
}

struct FolderSidebar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager
    @State private var newFolderPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("FILES")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(3)
                Spacer()
                Button(action: { browser.showAddFolder = true }) {
                    Image(systemName: "plus")
                        .foregroundColor(appState.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            Divider().background(Color.white.opacity(0.1))

            // Add folder input
            if browser.showAddFolder {
                VStack(spacing: 8) {
                    Text("Remote folder path:")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextField("/home/user/projects", text: $newFolderPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(6)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(4)
                        .onSubmit {
                            browser.addFolder(newFolderPath)
                            newFolderPath = ""
                            browser.showAddFolder = false
                        }

                    HStack(spacing: 8) {
                        Button("Add") {
                            browser.addFolder(newFolderPath)
                            newFolderPath = ""
                            browser.showAddFolder = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(appState.accentColor)

                        Button("Cancel") {
                            newFolderPath = ""
                            browser.showAddFolder = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.03))

                Divider().background(Color.white.opacity(0.1))
            }

            // Folder list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browser.savedFolders, id: \.self) { folder in
                        FolderRow(
                            path: folder,
                            isSelected: browser.currentPath?.hasPrefix(folder) == true,
                            accentColor: appState.accentColor
                        )
                        .onTapGesture {
                            browser.pathHistory = []
                            browser.fileContent = nil
                            browser.viewingFileName = nil
                            browser.currentPath = folder
                            browser.navigateTo(folder)
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                browser.removeFolder(folder)
                            }
                        }
                    }
                }
            }

            if !browser.savedFolders.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                Text("right-click to remove")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
                    .padding(8)
            }
        }
        .background(Color.black.opacity(0.4))
    }
}

struct FolderRow: View {
    let path: String
    let isSelected: Bool
    let accentColor: Color

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? accentColor : .gray.opacity(0.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(isSelected ? accentColor : .white.opacity(0.8))
                    .lineLimit(1)

                Text(path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
    }
}

struct NavigationBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager

    var body: some View {
        HStack(spacing: 8) {
            // Back button
            Button(action: { browser.navigateBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        (browser.currentPath != nil) ? appState.accentColor : .gray.opacity(0.3)
                    )
            }
            .buttonStyle(.plain)
            .disabled(browser.currentPath == nil)

            if let fileName = browser.viewingFileName {
                Image(systemName: iconForFile(fileName))
                    .font(.system(size: 11))
                    .foregroundColor(appState.accentColor)
                Text(fileName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
            } else if let path = browser.currentPath {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundColor(appState.accentColor.opacity(0.6))
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.03))
    }
}

struct DirectoryListView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(browser.entries) { entry in
                    EntryRow(entry: entry, accentColor: appState.accentColor)
                        .onTapGesture {
                            browser.openEntry(entry)
                        }
                }
            }
        }
    }
}

struct EntryRow: View {
    let entry: RemoteEntry
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : iconForFile(entry.name))
                .font(.system(size: 12))
                .foregroundColor(entry.isDirectory ? accentColor.opacity(0.7) : .gray.opacity(0.5))
                .frame(width: 16)

            Text(entry.name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(entry.isDirectory ? .white.opacity(0.9) : .white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            if !entry.isDirectory {
                Text(entry.size)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }

            Text(entry.modified)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct FileContentView: View {
    let fileName: String
    let content: String
    let accentColor: Color
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
        }
    }
}

// MARK: - File Icon Helper

private func iconForFile(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift", "rs", "go", "py", "rb", "js", "ts", "c", "cpp", "h", "java", "kt":
        return "chevron.left.forwardslash.chevron.right"
    case "json", "yaml", "yml", "toml", "xml", "plist":
        return "doc.text"
    case "md", "txt", "rst":
        return "doc.plaintext"
    case "png", "jpg", "jpeg", "gif", "svg", "ico":
        return "photo"
    case "sh", "bash", "zsh", "fish":
        return "terminal"
    case "lock":
        return "lock"
    case "gitignore", "dockerignore":
        return "eye.slash"
    default:
        return "doc"
    }
}
