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

// MARK: - Search Tree Model

public class SearchTreeNode: Identifiable, ObservableObject {
    public let id = UUID()
    public let name: String
    public let fullPath: String
    public let isDirectory: Bool
    @Published public var children: [SearchTreeNode] = []
    @Published public var isExpanded: Bool = true

    public init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }
}

public class SearchResultTree: ObservableObject {
    @Published public var roots: [SearchTreeNode] = []
    @Published public var resultCount: Int = 0
    public let maxResults = 100

    /// Insert a path into the tree relative to a base directory
    public func insertPath(_ relativePath: String, basePath: String) {
        guard resultCount < maxResults else { return }

        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        resultCount += 1

        var currentChildren = roots
        var currentFullPath = basePath
        var parentNode: SearchTreeNode? = nil

        for (i, component) in components.enumerated() {
            currentFullPath = currentFullPath.hasSuffix("/")
                ? "\(currentFullPath)\(component)"
                : "\(currentFullPath)/\(component)"
            let isLast = i == components.count - 1

            if let existing = currentChildren.first(where: { $0.name == component }) {
                parentNode = existing
                currentChildren = existing.children
            } else {
                let node = SearchTreeNode(
                    name: component,
                    fullPath: currentFullPath,
                    isDirectory: !isLast
                )
                if let parent = parentNode {
                    parent.children.append(node)
                    parent.children.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                } else {
                    roots.append(node)
                    roots.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                parentNode = node
                currentChildren = node.children
            }
        }
    }

    public func clear() {
        roots = []
        resultCount = 0
    }
}

public struct SavedFolder: Codable, Identifiable, Equatable {
    public var id: String { "\(hostID.uuidString):\(path)" }
    public let path: String
    public let hostID: UUID

    public init(path: String, hostID: UUID) {
        self.path = path
        self.hostID = hostID
    }
}

public struct RecentFile: Identifiable, Equatable, Codable {
    public var id: String { "\(hostID.uuidString):\(path)" }
    public let path: String
    public let name: String
    public let hostID: UUID

    public init(path: String, name: String, hostID: UUID) {
        self.path = path
        self.name = name
        self.hostID = hostID
    }
}

public class FileBrowserManager: ObservableObject {
    @Published public var savedFolders: [SavedFolder] = []
    @Published public var currentPath: String?
    @Published public var entries: [RemoteEntry] = []
    @Published public var fileContent: String?
    @Published public var imageData: Data?
    @Published public var viewingFileName: String?
    /// True when the file can't be previewed (binary, unknown format)
    @Published public var isUnsupportedFile = false
    @Published public var isLoading = false
    @Published public var error: String?
    @Published public var showAddFolder = false
    @Published public var pathHistory: [String] = []

    /// Recently opened files (path, name, hostID) — most recent first
    @Published public var recentFiles: [RecentFile] = []
    private let maxRecentFiles = 20
    /// Whether we were in search mode before opening a file
    private var wasSearchActiveBeforeFile = false

    /// Folders for the currently active host
    public var activeFolders: [SavedFolder] {
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        return savedFolders.filter { $0.hostID == hostID }
    }

    /// When true, single-child directory chains are collapsed into combined paths
    @Published public var collapsePaths = true
    /// Collapsed directory entries: maps display name → resolved full path
    @Published public var collapsedEntries: [RemoteEntry] = []
    @Published public var isCollapsingPaths = false

    // Search state
    @Published public var searchQuery: String = ""
    @Published public var isSearching = false
    @Published public var searchResults = SearchResultTree()
    @Published public var isSearchActive = false
    private var searchProcess: Process?
    private var searchCancellable: AnyCancellable?

    private let appState: AppState
    private var gitCancellable: AnyCancellable?

    public lazy var gitManager: GitManager = {
        let g = GitManager(appState: appState)
        gitCancellable = g.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return g
    }()

    private var recentFilesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Onyx/recent-files.json")
    }

    public init(appState: AppState) {
        self.appState = appState
        loadSavedFolders()
        loadRecentFiles()
    }

    /// Recent files for the active host
    public var activeRecentFiles: [RecentFile] {
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        return recentFiles.filter { $0.hostID == hostID }
    }

    // MARK: - Persistence

    private func loadSavedFolders() {
        guard let data = try? Data(contentsOf: appState.savedFoldersURL) else { return }
        // Try new format first
        if let folders = try? JSONDecoder().decode([SavedFolder].self, from: data) {
            savedFolders = folders
        } else if let legacyPaths = try? JSONDecoder().decode([String].self, from: data) {
            // Migrate from old [String] format — assign to first host (or localhost)
            let hostID = appState.hosts.first?.id ?? HostConfig.localhostID
            savedFolders = legacyPaths.map { SavedFolder(path: $0, hostID: hostID) }
            saveFolders()
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(savedFolders) {
            try? data.write(to: appState.savedFoldersURL)
        }
    }

    private func loadRecentFiles() {
        guard let data = try? Data(contentsOf: recentFilesURL),
              let files = try? JSONDecoder().decode([RecentFile].self, from: data) else { return }
        recentFiles = files
    }

    private func saveRecentFiles() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            try? data.write(to: recentFilesURL)
        }
    }

    func trackRecentFile(path: String, name: String) {
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        let file = RecentFile(path: path, name: name, hostID: hostID)
        // Remove existing entry for same path, then prepend
        recentFiles.removeAll { $0.id == file.id }
        recentFiles.insert(file, at: 0)
        if recentFiles.count > maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
        }
        saveRecentFiles()
    }

    /// Open a recent file by path
    public func openRecentFile(_ file: RecentFile) {
        let parent = (file.path as NSString).deletingLastPathComponent
        if currentPath != parent {
            if let current = currentPath {
                pathHistory.append(current)
            }
            currentPath = parent
        }
        readFile(file.path, name: file.name)
    }

    public func addFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        let folder = SavedFolder(path: trimmed, hostID: hostID)
        guard !trimmed.isEmpty, !savedFolders.contains(folder) else { return }
        savedFolders.append(folder)
        saveFolders()
    }

    public func removeFolder(_ folder: SavedFolder) {
        savedFolders.removeAll { $0 == folder }
        saveFolders()
        if currentPath?.hasPrefix(folder.path) == true {
            currentPath = nil
            entries = []
            fileContent = nil
            imageData = nil
            isUnsupportedFile = false
            gitManager.clear()
        }
    }

    // MARK: - Navigation

    public func navigateTo(_ path: String) {
        fileContent = nil
        imageData = nil
        viewingFileName = nil
        isUnsupportedFile = false
        collapsedEntries = []
        if let current = currentPath {
            pathHistory.append(current)
        }
        currentPath = path
        listDirectory(path)
        gitManager.checkAndLoad(path: path)
    }

    public func navigateBack() {
        // If viewing a file and we came from search, return to search results
        if viewingFileName != nil && wasSearchActiveBeforeFile {
            fileContent = nil
            imageData = nil
            viewingFileName = nil
            isUnsupportedFile = false
            wasSearchActiveBeforeFile = false
            isSearchActive = true
            return
        }

        fileContent = nil
        imageData = nil
        viewingFileName = nil
        isUnsupportedFile = false
        wasSearchActiveBeforeFile = false
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

    /// Check if the currently viewed file has git changes, returning the GitChangedFile if so
    public func gitChangedFileForViewing() -> GitChangedFile? {
        guard let name = viewingFileName, let repoPath = gitManager.currentRepoPath, let status = gitManager.repoStatus else { return nil }
        guard let current = currentPath else { return nil }
        // Build relative path from repo root
        let fullPath = current.hasSuffix("/") ? current + name : current + "/" + name
        let relativePath: String
        if fullPath.hasPrefix(repoPath + "/") {
            relativePath = String(fullPath.dropFirst(repoPath.count + 1))
        } else if fullPath.hasPrefix(repoPath) {
            relativePath = String(fullPath.dropFirst(repoPath.count))
        } else {
            return nil
        }
        return status.changedFiles.first { $0.path == relativePath }
    }

    /// Refresh the current directory listing and git status
    public func listCurrentDirectory() {
        guard let path = currentPath else { return }
        collapsedEntries = []
        listDirectory(path)
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
        imageData = nil
        viewingFileName = nil
        isUnsupportedFile = false
    }

    /// Open a file by full path (used by search results)
    public func readFileFromSearch(_ path: String, name: String) {
        // Remember that we came from search so back returns to results
        wasSearchActiveBeforeFile = isSearchActive

        // Set the current path to the file's parent directory
        let parent = (path as NSString).deletingLastPathComponent
        if currentPath != parent {
            if let current = currentPath {
                pathHistory.append(current)
            }
            currentPath = parent
        }
        readFile(path, name: name)
    }

    // MARK: - Remote Operations

    /// Check if the active host is remote and has no connected sessions
    private func checkRemoteConnectivity() -> String? {
        guard let host = appState.activeHost, !host.isLocal else { return nil }
        let hasSession = appState.allSessions.contains { $0.source.hostID == host.id }
        if !hasSession {
            return "No active session to \(host.label).\nOpen a terminal session to this host first."
        }
        return nil
    }

    private func listDirectory(_ path: String) {
        if let connectError = checkRemoteConnectivity() {
            error = connectError
            return
        }

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
                        } else if self.collapsePaths {
                            self.resolveCollapsedPaths(path)
                        } else {
                            self.collapsedEntries = []
                        }
                    }
                } else {
                    self.error = "Failed to list directory"
                }
            }
        }
    }

    /// For each directory in entries, walk single-child directory chains and
    /// produce collapsed entries like "org/almostrealism/collect".
    /// Uses a single remote command that checks all directories at once.
    func resolveCollapsedPaths(_ basePath: String) {
        let dirs = entries.filter(\.isDirectory).map(\.name)
        guard !dirs.isEmpty else {
            collapsedEntries = []
            return
        }

        isCollapsingPaths = true
        let escaped = escapeForShell(basePath)

        // Shell script: for each directory, follow single-child chains.
        // Output: "original_dir\tresolved_relative_path" per line.
        // A directory is "single-child" if it contains exactly one entry and that entry is a directory.
        var scriptParts: [String] = []
        for dir in dirs {
            let safeDir = dir.replacingOccurrences(of: "'", with: "'\\''")
            scriptParts.append("""
            d='\(safeDir)'; p="$d"; \
            while true; do \
            c=$(ls -1A \(escaped)/"$p" 2>/dev/null); \
            n=$(echo "$c" | grep -c .); \
            if [ "$n" -eq 1 ] && [ -d \(escaped)/"$p/$c" ]; then \
            p="$p/$c"; else break; fi; done; \
            echo "$d\t$p"
            """)
        }
        let script = scriptParts.joined(separator: "; ")
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCollapsingPaths = false

                // Parse output: "original\tresolved" per line
                var collapsed: [String: String] = [:]  // original name → resolved relative path
                for line in output.components(separatedBy: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let original = parts[0].trimmingCharacters(in: .whitespaces)
                    let resolved = parts[1].trimmingCharacters(in: .whitespaces)
                    if resolved != original && !resolved.isEmpty {
                        collapsed[original] = resolved
                    }
                }

                // Build collapsed entries list: replace directory entries with collapsed versions
                self.collapsedEntries = self.entries.map { entry in
                    guard entry.isDirectory, let resolved = collapsed[entry.name] else { return entry }
                    return RemoteEntry(
                        name: resolved,
                        isDirectory: true,
                        size: entry.size,
                        modified: entry.modified
                    )
                }
            }
        }
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "ico", "heic", "heif"
    ]

    private static let binaryExtensions: Set<String> = [
        "zip", "tar", "gz", "bz2", "xz", "7z", "rar",
        "exe", "dll", "dylib", "so", "o", "a",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "mp3", "mp4", "mov", "avi", "mkv", "wav", "flac", "ogg",
        "ttf", "otf", "woff", "woff2",
        "sqlite", "db", "bin", "dat",
        "class", "pyc", "wasm",
    ]

    private enum FileKind {
        case text
        case image
        case binary
    }

    private static func classifyFile(_ name: String) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if binaryExtensions.contains(ext) { return .binary }
        return .text
    }

    private func readFile(_ path: String, name: String) {
        if let connectError = checkRemoteConnectivity() {
            error = connectError
            return
        }

        trackRecentFile(path: path, name: name)

        isLoading = true
        error = nil
        imageData = nil
        isUnsupportedFile = false

        let kind = Self.classifyFile(name)
        let escaped = escapeForShell(path)

        switch kind {
        case .image:
            readImageFile(path: escaped, name: name)
        case .binary:
            // Don't try to read — just show the unsupported file view
            DispatchQueue.main.async {
                self.isLoading = false
                self.viewingFileName = name
                self.isUnsupportedFile = true
            }
        case .text:
            readTextFile(path: escaped, name: name)
        }
    }

    private func readTextFile(path escaped: String, name: String) {
        // Check if file is actually binary (even if extension looks like text)
        // Read first 2000 lines, but first check if it's binary with file(1)
        let script = """
        FILE_TYPE=$(file -b --mime-encoding \(escaped) 2>/dev/null); \
        if echo "$FILE_TYPE" | grep -qi binary; then echo "__BINARY__"; \
        else head -2000 \(escaped) 2>&1; fi
        """
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
                    if output.trimmingCharacters(in: .whitespacesAndNewlines) == "__BINARY__" {
                        self.viewingFileName = name
                        self.isUnsupportedFile = true
                    } else {
                        self.fileContent = output
                        self.viewingFileName = name
                    }
                } else {
                    self.error = "Failed to read file"
                }
            }
        }
    }

    private func readImageFile(path escaped: String, name: String) {
        // Base64-encode the image and transfer as text
        let script = "base64 < \(escaped) 2>&1"
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProcessWithStatus(cmd: cmd, args: args)
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let self = self else { return }
                if result.exitCode == 255 {
                    let host = self.appState.activeHost?.label ?? "remote host"
                    self.error = "Cannot connect to \(host).\nOpen a terminal session to this host first."
                } else if let output = result.output,
                          let data = Data(base64Encoded: output.trimmingCharacters(in: .whitespacesAndNewlines),
                                          options: .ignoreUnknownCharacters),
                          !data.isEmpty {
                    self.imageData = data
                    self.viewingFileName = name
                } else {
                    // Failed to decode — show as unsupported with download option
                    self.viewingFileName = name
                    self.isUnsupportedFile = true
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

    // MARK: - Search

    public func startSearch(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let basePath = currentPath ?? activeFolders.first?.path else { return }

        if let connectError = checkRemoteConnectivity() {
            error = connectError
            return
        }

        cancelSearch()
        isSearchActive = true
        isSearching = true
        searchResults.clear()

        let escaped = escapeForShell(basePath)
        // Use find with -iname for case-insensitive name matching, limit output
        // Avoid single quotes since remoteCommand wraps in single quotes for SSH
        let safeQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "find \(escaped) -maxdepth 10 -name \".*\" -prune -o -iname \"*\(safeQuery)*\" -print 2>/dev/null | head -\(searchResults.maxResults)"
        let (cmd, args) = appState.remoteCommand(script)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let baseForStripping = basePath.hasSuffix("/") ? basePath : basePath + "/"

        // Read output progressively line by line
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else {
                // EOF
                return
            }

            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Strip base path prefix to get relative path
                    let relative: String
                    if trimmed.hasPrefix(baseForStripping) {
                        relative = String(trimmed.dropFirst(baseForStripping.count))
                    } else if trimmed == basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) || trimmed == basePath {
                        continue // skip the base directory itself
                    } else {
                        relative = trimmed
                    }
                    guard !relative.isEmpty else { continue }

                    DispatchQueue.main.async {
                        self.searchResults.insertPath(relative, basePath: basePath)
                    }
                }
            }
        }

        // Set up a kill timer (30 seconds max)
        let killTimer = DispatchSource.makeTimerSource(queue: .global())
        killTimer.schedule(deadline: .now() + 30)
        killTimer.setEventHandler { if process.isRunning { process.terminate() } }
        killTimer.resume()

        searchProcess = process

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // ignore
            }
            killTimer.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                self?.isSearching = false
            }
        }
    }

    public func cancelSearch() {
        if let process = searchProcess, process.isRunning {
            process.terminate()
        }
        searchProcess = nil
        isSearching = false
    }

    public func clearSearch() {
        cancelSearch()
        searchQuery = ""
        searchResults.clear()
        isSearchActive = false
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
        guard let host = appState.activeHost else { return false }
        var args = appState.scpBaseArgs(for: host)
        args.append("-r")  // recursive for directories
        args.append(url.path)
        args.append("\(appState.sshUserHost(for: host)):\(dest)/")

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

    // MARK: - Download

    @Published public var downloadStatus: String?
    @Published public var isDownloading = false

    public func downloadEntry(_ entry: RemoteEntry) {
        guard let current = currentPath else { return }
        let fullPath = current.hasSuffix("/") ? "\(current)\(entry.name)" : "\(current)/\(entry.name)"
        downloadPath(fullPath, isDirectory: entry.isDirectory)
    }

    public func downloadPath(_ remotePath: String, isDirectory: Bool) {
        // Show save panel to pick local destination
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (remotePath as NSString).lastPathComponent
        panel.canCreateDirectories = true
        if isDirectory {
            // For directories, treat the name as a folder
            panel.nameFieldStringValue = (remotePath as NSString).lastPathComponent
        }
        guard panel.runModal() == .OK, let destURL = panel.url else { return }

        isDownloading = true
        downloadStatus = "Downloading \((remotePath as NSString).lastPathComponent)..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success: Bool
            if self.appState.activeHost?.isLocal ?? true {
                success = self.copyLocalDown(remotePath, to: destURL, isDirectory: isDirectory)
            } else {
                success = self.scpDownload(remotePath, to: destURL, isDirectory: isDirectory)
            }

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadStatus = success ? "Download complete" : "Download failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.downloadStatus?.hasPrefix("Download") == true {
                        self.downloadStatus = nil
                    }
                }
            }
        }
    }

    private func copyLocalDown(_ remotePath: String, to destURL: URL, isDirectory: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = isDirectory ? ["-R", remotePath, destURL.path] : [remotePath, destURL.path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func scpDownload(_ remotePath: String, to destURL: URL, isDirectory: Bool) -> Bool {
        guard let host = appState.activeHost else { return false }
        var args = appState.scpBaseArgs(for: host)
        if isDirectory { args.append("-r") }
        args.append("\(appState.sshUserHost(for: host)):\(remotePath)")
        args.append(destURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = args
        do {
            try process.run()

            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + 60)
            killTimer.setEventHandler { if process.isRunning { process.terminate() } }
            killTimer.resume()

            process.waitUntilExit()
            killTimer.cancel()
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
    @ObservedObject var browser: FileBrowserManager
    @State private var isDragOver = false

    init(appState: AppState) {
        self.appState = appState
        self.browser = appState.fileBrowserManager
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
                    } else if let data = browser.imageData {
                        ImageContentView(
                            fileName: browser.viewingFileName ?? "image",
                            imageData: data,
                            accentColor: appState.accentColor,
                            onClose: { browser.closeFile() },
                            onDownload: {
                                if let path = browser.currentPath, let name = browser.viewingFileName {
                                    let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                                    browser.downloadPath(fullPath, isDirectory: false)
                                }
                            }
                        )
                    } else if browser.isUnsupportedFile {
                        UnsupportedFileView(
                            fileName: browser.viewingFileName ?? "file",
                            accentColor: appState.accentColor,
                            onClose: { browser.closeFile() },
                            onDownload: {
                                if let path = browser.currentPath, let name = browser.viewingFileName {
                                    let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                                    browser.downloadPath(fullPath, isDirectory: false)
                                }
                            }
                        )
                    } else if let content = browser.fileContent {
                        FileContentView(
                            fileName: browser.viewingFileName ?? "file",
                            content: content,
                            accentColor: appState.accentColor,
                            onClose: { browser.closeFile() },
                            onDownload: {
                                if let path = browser.currentPath, let name = browser.viewingFileName {
                                    let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                                    browser.downloadPath(fullPath, isDirectory: false)
                                }
                            },
                            onViewDiff: browser.gitChangedFileForViewing().map { file in
                                { browser.gitManager.fetchFileDiff(file) }
                            }
                        )
                    } else if browser.gitManager.showLog {
                        GitLogView(gitManager: browser.gitManager, accentColor: appState.accentColor)
                    } else if browser.isSearchActive {
                        SearchResultsView(appState: appState, browser: browser, tree: browser.searchResults)
                    } else if browser.currentPath != nil {
                        VStack(spacing: 0) {
                            if browser.gitManager.isGitRepo, let status = browser.gitManager.repoStatus {
                                GitLandingView(
                                    status: status,
                                    accentColor: appState.accentColor,
                                    gitManager: browser.gitManager,
                                    onTrackFile: { path, name in
                                        browser.trackRecentFile(path: path, name: name)
                                    },
                                    onViewFile: { path, name in
                                        browser.readFileFromSearch(path, name: name)
                                    }
                                )
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
                    // Transfer status bars (upload / download)
                    ForEach(transferStatuses, id: \.text) { status in
                        HStack(spacing: 8) {
                            if status.inProgress {
                                ProgressView().scaleEffect(0.6).colorScheme(.dark)
                            } else if status.text.contains("failed") || status.text.hasPrefix("Failed") {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "FF6B6B"))
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "6BFF8E"))
                            }
                            Text(status.text)
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
        .onChange(of: appState.allSessions.count) {
            // Auto-retry if we had a connectivity error and sessions just appeared
            if let error = browser.error,
               error.contains("No active session"),
               let path = browser.currentPath {
                browser.navigateTo(path)
            }
        }
    }

    private struct TransferStatus: Hashable {
        let text: String
        let inProgress: Bool
    }

    private var transferStatuses: [TransferStatus] {
        var statuses: [TransferStatus] = []
        if let s = browser.uploadStatus {
            statuses.append(TransferStatus(text: s, inProgress: browser.isUploading))
        }
        if let s = browser.downloadStatus {
            statuses.append(TransferStatus(text: s, inProgress: browser.isDownloading))
        }
        return statuses
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
                    ForEach(browser.activeFolders) { folder in
                        FolderRow(
                            path: folder.path,
                            hostLabel: appState.hosts.count > 1 ? appState.host(for: folder.hostID)?.label : nil,
                            isSelected: browser.currentPath?.hasPrefix(folder.path) == true,
                            accentColor: appState.accentColor
                        )
                        .onTapGesture {
                            browser.pathHistory = []
                            browser.fileContent = nil
                            browser.imageData = nil
                            browser.viewingFileName = nil
                            browser.isUnsupportedFile = false
                            browser.currentPath = folder.path
                            browser.navigateTo(folder.path)
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                browser.removeFolder(folder)
                            }
                        }
                    }
                }
            }

            // Recent files section
            if !browser.activeRecentFiles.isEmpty {
                Divider().background(Color.white.opacity(0.1))

                HStack {
                    Text("RECENT")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                        .tracking(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(browser.activeRecentFiles) { file in
                            HStack(spacing: 6) {
                                Image(systemName: iconForFile(file.name))
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray.opacity(0.4))
                                    .frame(width: 14)

                                Text(file.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.7))
                                    .lineLimit(1)

                                Spacer()

                                Text((file.path as NSString).deletingLastPathComponent.split(separator: "/").suffix(2).joined(separator: "/"))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.25))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                browser.openRecentFile(file)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            if !browser.activeFolders.isEmpty {
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
    var hostLabel: String? = nil
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
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(isSelected ? accentColor : .white.opacity(0.8))
                        .lineLimit(1)

                    if let host = hostLabel {
                        Text(host)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(accentColor.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(accentColor.opacity(0.1))
                            .cornerRadius(2)
                    }
                }

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
    @State private var searchFieldFocused = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Back button
                Button(action: {
                    // If viewing a file (from search or directory), navigate back
                    if browser.viewingFileName != nil {
                        browser.navigateBack()
                    } else if browser.isSearchActive {
                        browser.clearSearch()
                    } else {
                        browser.navigateBack()
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(
                            (browser.currentPath != nil || browser.isSearchActive || browser.viewingFileName != nil) ? appState.accentColor : .gray.opacity(0.3)
                        )
                }
                .buttonStyle(.plain)
                .disabled(browser.currentPath == nil && !browser.isSearchActive && browser.viewingFileName == nil)

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

                // Collapse paths toggle
                if browser.currentPath != nil && browser.viewingFileName == nil {
                    Button(action: {
                        browser.collapsePaths.toggle()
                        if browser.collapsePaths, let path = browser.currentPath {
                            browser.resolveCollapsedPaths(path)
                        } else {
                            browser.collapsedEntries = []
                        }
                    }) {
                        Image(systemName: "arrow.right.to.line.compact")
                            .font(.system(size: 12))
                            .foregroundColor(browser.collapsePaths ? appState.accentColor : .gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Collapse single-child directories")
                }

                // Refresh button
                if browser.currentPath != nil {
                    Button(action: {
                        if let path = browser.currentPath {
                            browser.listCurrentDirectory()
                            browser.gitManager.checkAndLoad(path: path)
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                // Git history button
                if browser.gitManager.isGitRepo {
                    Button(action: {
                        if browser.gitManager.showLog {
                            browser.gitManager.closeLog()
                        } else {
                            browser.gitManager.fetchLog()
                        }
                    }) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                            .foregroundColor(browser.gitManager.showLog ? appState.accentColor : .gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                // Search button
                if browser.currentPath != nil || !browser.activeFolders.isEmpty {
                    Button(action: {
                        if browser.isSearchActive {
                            browser.clearSearch()
                        } else {
                            browser.isSearchActive = true
                        }
                    }) {
                        Image(systemName: browser.isSearchActive ? "xmark.circle.fill" : "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(browser.isSearchActive ? appState.accentColor : .gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search bar
            if browser.isSearchActive {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.5))

                    TextField("Search files by name...", text: $browser.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .onSubmit {
                            browser.startSearch(browser.searchQuery)
                        }

                    if browser.isSearching {
                        ProgressView()
                            .scaleEffect(0.5)
                            .colorScheme(.dark)
                    }

                    if !browser.searchQuery.isEmpty {
                        Button(action: {
                            browser.searchQuery = ""
                            browser.searchResults.clear()
                            browser.cancelSearch()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
            }
        }
        .background(Color.white.opacity(0.03))
    }
}

struct DirectoryListView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager

    /// Use collapsed entries if available and collapse mode is on, otherwise raw entries
    private var displayEntries: [RemoteEntry] {
        if browser.collapsePaths && !browser.collapsedEntries.isEmpty {
            return browser.collapsedEntries
        }
        return browser.entries
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(displayEntries) { entry in
                    EntryRow(entry: entry, accentColor: appState.accentColor)
                        .onTapGesture {
                            if entry.isDirectory {
                                // Navigate to the full resolved path
                                guard let current = browser.currentPath else { return }
                                let fullPath = current.hasSuffix("/") ? "\(current)\(entry.name)" : "\(current)/\(entry.name)"
                                browser.navigateTo(fullPath)
                            } else {
                                browser.openEntry(entry)
                            }
                        }
                        .contextMenu {
                            Button(action: { browser.downloadEntry(entry) }) {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                        }
                }
            }
        }
    }
}

struct SearchResultsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager
    @ObservedObject var tree: SearchResultTree

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tree.roots.isEmpty && !browser.isSearching {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.gray.opacity(0.3))
                    if browser.searchQuery.isEmpty {
                        Text("Type a filename and press Enter")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    } else {
                        Text("No results found")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Result count header
                HStack {
                    Text("\(tree.resultCount) result\(tree.resultCount == 1 ? "" : "s")\(tree.resultCount >= tree.maxResults ? " (limit reached)" : "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                    Spacer()
                    if browser.isSearching {
                        Text("searching...")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(appState.accentColor.opacity(0.6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(tree.roots) { node in
                            SearchTreeNodeView(node: node, depth: 0, accentColor: appState.accentColor, browser: browser)
                        }
                    }
                }
            }
        }
    }
}

struct SearchTreeNodeView: View {
    @ObservedObject var node: SearchTreeNode
    let depth: Int
    let accentColor: Color
    @ObservedObject var browser: FileBrowserManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                // Indent
                Spacer().frame(width: CGFloat(depth) * 16)

                if node.isDirectory {
                    // Expand/collapse toggle
                    Button(action: { node.isExpanded.toggle() }) {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.4))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(accentColor.opacity(0.7))
                } else {
                    Spacer().frame(width: 12) // align with folder toggle

                    Image(systemName: iconForFile(node.name))
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.5))
                }

                Text(node.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(node.isDirectory ? .white.opacity(0.9) : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if node.isDirectory {
                    // Navigate into this directory
                    browser.clearSearch()
                    browser.navigateTo(node.fullPath)
                } else {
                    // Open the file
                    let name = (node.fullPath as NSString).lastPathComponent
                    browser.clearSearch()
                    browser.readFileFromSearch(node.fullPath, name: name)
                }
            }

            if node.isDirectory && node.isExpanded {
                ForEach(node.children) { child in
                    SearchTreeNodeView(node: child, depth: depth + 1, accentColor: accentColor, browser: browser)
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
    var onDownload: (() -> Void)? = nil
    var onViewDiff: (() -> Void)? = nil

    private var highlightedContent: AttributedString {
        SyntaxHighlighter.highlight(content, fileName: fileName)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                if let viewDiff = onViewDiff {
                    Button(action: viewDiff) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 10))
                            Text("Diff")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(accentColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if let download = onDownload {
                    Button(action: download) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 10))
                            Text("Download")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(accentColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.03))

            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(highlightedContent)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
        }
    }
}

// MARK: - Syntax Highlighting

enum SyntaxHighlighter {
    // Theme colors (dark background friendly)
    private static let keyword = Color(hex: "C06BFF")     // purple
    private static let type = Color(hex: "66CCFF")         // blue
    private static let string = Color(hex: "6BFF8E")       // green
    private static let comment = Color(hex: "6B7280")      // gray
    private static let number = Color(hex: "FFD06B")       // yellow
    private static let annotation = Color(hex: "FFD06B")   // yellow
    private static let plain = Color.white.opacity(0.85)

    /// Supported file extensions → language
    private static let languages: [String: Language] = [
        "java": .java, "kt": .kotlin,
        "swift": .swift,
        "js": .javascript, "ts": .typescript, "jsx": .javascript, "tsx": .typescript,
        "py": .python,
        "go": .go,
        "rs": .rust,
        "c": .c, "cpp": .c, "h": .c, "hpp": .c, "cc": .c,
        "rb": .ruby,
        "sh": .shell, "bash": .shell, "zsh": .shell,
        "json": .json,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "xml": .xml, "html": .xml, "htm": .xml, "plist": .xml, "svg": .xml,
    ]

    enum Language {
        case java, kotlin, swift, javascript, typescript, python, go, rust, c, ruby, shell, json, yaml, toml, xml
    }

    static func highlight(_ content: String, fileName: String) -> AttributedString {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let language = languages[ext] else {
            var attr = AttributedString(content)
            attr.foregroundColor = plain
            return attr
        }
        return highlightCode(content, language: language)
    }

    private static func highlightCode(_ code: String, language: Language) -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = plain

        let rules = syntaxRules(for: language)
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let nsRange = NSRange(code.startIndex..., in: code)
            for match in regex.matches(in: code, range: nsRange) {
                let groupIndex = rule.captureGroup
                let matchRange = groupIndex < match.numberOfRanges ? match.range(at: groupIndex) : match.range
                guard matchRange.location != NSNotFound,
                      let range = Range(matchRange, in: code) else { continue }
                let offset = code.distance(from: code.startIndex, to: range.lowerBound)
                let length = code.distance(from: range.lowerBound, to: range.upperBound)
                let start = result.index(result.startIndex, offsetByCharacters: offset)
                let end = result.index(start, offsetByCharacters: length)
                result[start..<end].foregroundColor = rule.color
            }
        }
        return result
    }

    private struct Rule {
        let pattern: String
        let color: Color
        let options: NSRegularExpression.Options
        let captureGroup: Int

        init(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = [], group: Int = 0) {
            self.pattern = pattern
            self.color = color
            self.options = options
            self.captureGroup = group
        }
    }

    private static func syntaxRules(for language: Language) -> [Rule] {
        // Order matters: numbers → keywords → types → annotations → strings → comments
        // Later rules override earlier ones at the same position
        switch language {
        case .java:
            return javaRules()
        case .kotlin:
            return kotlinRules()
        case .swift:
            return swiftRules()
        case .javascript, .typescript:
            return jsRules()
        case .python:
            return pythonRules()
        case .go:
            return goRules()
        case .rust:
            return rustRules()
        case .c:
            return cRules()
        case .ruby:
            return rubyRules()
        case .shell:
            return shellRules()
        case .json:
            return jsonRules()
        case .yaml:
            return yamlRules()
        case .toml:
            return tomlRules()
        case .xml:
            return xmlRules()
        }
    }

    // MARK: - Language Rules

    private static func javaRules() -> [Rule] {
        let keywords = "abstract|assert|boolean|break|byte|case|catch|char|class|const|continue|default|do|double|else|enum|extends|final|finally|float|for|goto|if|implements|import|instanceof|int|interface|long|native|new|package|private|protected|public|return|short|static|strictfp|super|switch|synchronized|this|throw|throws|transient|try|var|void|volatile|while|yield|record|sealed|permits|non-sealed"
        let types = "String|Integer|Long|Double|Float|Boolean|Byte|Short|Character|Object|List|Map|Set|ArrayList|HashMap|HashSet|Optional|Stream|Collection|Iterator|Iterable|Comparable|Runnable|Callable|Future|Thread|Exception|Error|Override|Deprecated|SuppressWarnings|FunctionalInterface"
        return [
            Rule(#"\b(\d+\.?\d*[fFdDlL]?)\b"#, number),
            Rule(#"\b(0x[0-9a-fA-F]+[lL]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|null)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func kotlinRules() -> [Rule] {
        let keywords = "abstract|actual|annotation|as|break|by|catch|class|companion|const|constructor|continue|crossinline|data|delegate|do|dynamic|else|enum|expect|external|final|finally|for|fun|get|if|import|in|infix|init|inline|inner|interface|internal|is|it|lateinit|noinline|object|open|operator|out|override|package|private|protected|public|reified|return|sealed|set|super|suspend|tailrec|this|throw|try|typealias|val|var|vararg|when|where|while"
        return [
            Rule(#"\b(\d+\.?\d*[fFdDlL]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|null)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func swiftRules() -> [Rule] {
        let keywords = "actor|any|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|do|dynamic|else|enum|extension|fallthrough|fileprivate|final|for|func|get|guard|if|import|in|indirect|infix|init|inout|internal|is|isolated|lazy|let|mutating|nonisolated|nonmutating|open|operator|optional|override|package|postfix|precedencegroup|prefix|private|protocol|public|repeat|required|rethrows|return|set|some|static|struct|subscript|super|switch|throw|throws|try|typealias|unowned|var|weak|where|while|willSet|didSet"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|nil|self|Self)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func jsRules() -> [Rule] {
        let keywords = "abstract|arguments|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|enum|export|extends|finally|for|from|function|get|if|implements|import|in|instanceof|interface|let|new|of|package|private|protected|public|return|set|static|super|switch|this|throw|try|typeof|var|void|while|with|yield"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|null|undefined|NaN|Infinity)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"`(?:[^`\\]|\\.)*`"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func pythonRules() -> [Rule] {
        let keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield"
        return [
            Rule(#"\b(\d+\.?\d*[jJ]?)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(True|False|None|self|cls)\b"#, keyword),
            Rule(#"@\w+"#, annotation),
            Rule(#"f?"(?:[^"\\]|\\.)*""#, string),
            Rule(#"f?'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func goRules() -> [Rule] {
        let keywords = "break|case|chan|const|continue|default|defer|else|fallthrough|for|func|go|goto|if|import|interface|map|package|range|return|select|struct|switch|type|var"
        let types = "bool|byte|complex64|complex128|error|float32|float64|int|int8|int16|int32|int64|rune|string|uint|uint8|uint16|uint32|uint64|uintptr"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|nil|iota)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"`[^`]*`"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func rustRules() -> [Rule] {
        let keywords = "as|async|await|break|const|continue|crate|dyn|else|enum|extern|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|Self|static|struct|super|trait|type|union|unsafe|use|where|while"
        let types = "bool|char|f32|f64|i8|i16|i32|i64|i128|isize|str|u8|u16|u32|u64|u128|usize|String|Vec|Option|Result|Box|Rc|Arc"
        return [
            Rule(#"\b(\d+\.?\d*[_]?[fiu]?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule("\\b(\(types))\\b", type),
            Rule(#"\b(true|false|None|Some|Ok|Err)\b"#, keyword),
            Rule(#"#\[[\w(,= ]*\]"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func cRules() -> [Rule] {
        let keywords = "auto|break|case|char|const|continue|default|do|double|else|enum|extern|float|for|goto|if|inline|int|long|register|restrict|return|short|signed|sizeof|static|struct|switch|typedef|union|unsigned|void|volatile|while|class|namespace|template|typename|using|public|private|protected|virtual|override|new|delete|try|catch|throw|nullptr"
        return [
            Rule(#"\b(\d+\.?\d*[fFlLuU]*)\b"#, number),
            Rule(#"\b(0x[0-9a-fA-F]+[uUlL]*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|NULL|nullptr)\b"#, keyword),
            Rule(#"#\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            Rule(#"/\*[\s\S]*?\*/"#, comment, options: .dotMatchesLineSeparators),
        ]
    }

    private static func rubyRules() -> [Rule] {
        let keywords = "alias|and|begin|break|case|class|def|defined|do|else|elsif|end|ensure|for|if|in|module|next|not|or|redo|rescue|retry|return|self|super|then|undef|unless|until|when|while|yield"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\b(true|false|nil)\b"#, keyword),
            Rule(#":\w+"#, annotation),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'(?:[^'\\]|\\.)*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func shellRules() -> [Rule] {
        let keywords = "if|then|else|elif|fi|for|while|do|done|case|esac|in|function|return|local|export|readonly|declare|typeset|unset|shift|break|continue|eval|exec|exit|trap|source"
        return [
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule("\\b(\(keywords))\\b", keyword),
            Rule(#"\$\w+"#, type),
            Rule(#"\$\{[^}]+\}"#, type),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func jsonRules() -> [Rule] {
        return [
            Rule(#""(?:[^"\\]|\\.)*"\s*:"#, type),  // keys
            Rule(#":\s*"(?:[^"\\]|\\.)*""#, string), // string values
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false|null)\b"#, keyword),
        ]
    }

    private static func yamlRules() -> [Rule] {
        return [
            Rule(#"^[\w.-]+(?=\s*:)"#, type, options: .anchorsMatchLines), // keys
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false|null|yes|no|on|off)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func tomlRules() -> [Rule] {
        return [
            Rule(#"\[[\w.-]+\]"#, type),             // section headers
            Rule(#"^[\w.-]+(?=\s*=)"#, type, options: .anchorsMatchLines), // keys
            Rule(#"\b(\d+\.?\d*)\b"#, number),
            Rule(#"\b(true|false)\b"#, keyword),
            Rule(#""(?:[^"\\]|\\.)*""#, string),
            Rule(#"'[^']*'"#, string),
            Rule(#"#.*$"#, comment, options: .anchorsMatchLines),
        ]
    }

    private static func xmlRules() -> [Rule] {
        return [
            Rule(#"</?[\w:-]+"#, keyword),            // tag names
            Rule(#"/?\s*>"#, keyword),                 // closing >
            Rule(#"\b[\w:-]+(?=\s*=)"#, type),        // attribute names
            Rule(#""[^"]*""#, string),                 // attribute values
            Rule(#"'[^']*'"#, string),
            Rule(#"<!--[\s\S]*?-->"#, comment, options: .dotMatchesLineSeparators),
        ]
    }
}

struct ImageContentView: View {
    let fileName: String
    let imageData: Data
    let accentColor: Color
    let onClose: () -> Void
    var onDownload: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Action bar
            HStack {
                Spacer()
                if let download = onDownload {
                    Button(action: download) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 10))
                            Text("Download")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(accentColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.03))

            // Image
            ScrollView([.horizontal, .vertical]) {
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                } else {
                    // Data exists but couldn't create image — corrupt or unsupported codec
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 32))
                            .foregroundColor(.gray.opacity(0.4))
                        Text("Cannot render image")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
        }
    }
}

struct UnsupportedFileView: View {
    let fileName: String
    let accentColor: Color
    let onClose: () -> Void
    var onDownload: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.35))

            Text("Cannot preview this file")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.6))

            Text(fileName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))

            if let download = onDownload {
                Button(action: download) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                        Text("Download")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(accentColor.opacity(0.15))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
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
