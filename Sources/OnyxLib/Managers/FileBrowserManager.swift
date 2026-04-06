//
// FileBrowserManager.swift
//
// Responsibility: Remote/local file browsing — saved folders, directory
//                 listing, file preview (text/image/binary), search, recent
//                 files, and path-collapsing. Owns the per-window GitManager.
// Scope: Per-window (lives on AppState); all per-host state is keyed by host.
// Threading: Main actor for @Published state; shell-out work runs on
//            DispatchQueue.global(.userInitiated) and bounces back to main.
//            A long-running search Process is tracked and cancellable.
// Invariants:
//   - savedFolders / recentFiles are filtered by activeHost.id at read time
//   - currentPath, when set, refers to a path on the currently active host
//   - At most one searchProcess is running at a time
//   - recentFiles is bounded by maxRecentFiles per host
//
// See: ADR-004 (per-host isolation)
//

import Foundation
import Combine
import AppKit

/// FileBrowserManager.
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

    /// Git manager.
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

    /// Create a new instance.
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

    /// Add folder.
    public func addFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = appState.activeHost?.id ?? HostConfig.localhostID
        let folder = SavedFolder(path: trimmed, hostID: hostID)
        guard !trimmed.isEmpty, !savedFolders.contains(folder) else { return }
        savedFolders.append(folder)
        saveFolders()
    }

    /// Remove folder.
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

    /// Navigate to.
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

    /// Navigate back.
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

    /// Status message for dependency analysis
    @Published public var depsStatus: String?

    /// Analyze Java dependency graph and show as artifact diagram
    public func analyzeDependencies(repoPath: String, appState: AppState) {
        depsStatus = "Analyzing dependencies..."
        print("analyzeDependencies: starting for \(repoPath)")

        let analyzer = DependencyAnalyzer(appState: appState)
        analyzer.analyze(repoPath: repoPath) { [weak self] mermaid in
            if let mermaid = mermaid, !mermaid.isEmpty {
                print("analyzeDependencies: got \(mermaid.count) chars of Mermaid")
                let content = ArtifactContent.diagram(content: mermaid, format: .mermaid)
                _ = appState.artifactManager.setSlot(0, title: "Dependency Graph", content: content)
                appState.activeRightPanel = .artifacts
                self?.depsStatus = nil
            } else {
                print("analyzeDependencies: no output returned")
                self?.depsStatus = "No dependency data (need python3 + Java files)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self?.depsStatus?.hasPrefix("No dep") == true {
                        self?.depsStatus = nil
                    }
                }
            }
        }
    }

    /// Refresh the current directory listing and git status
    public func listCurrentDirectory() {
        guard let path = currentPath else { return }
        collapsedEntries = []
        listDirectory(path)
    }

    /// Open entry.
    public func openEntry(_ entry: RemoteEntry) {
        guard let current = currentPath else { return }
        let fullPath = current.hasSuffix("/") ? "\(current)\(entry.name)" : "\(current)/\(entry.name)"
        if entry.isDirectory {
            navigateTo(fullPath)
        } else {
            readFile(fullPath, name: entry.name)
        }
    }

    /// Close file.
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

    /// Check basic connectivity prerequisites.
    /// No longer checks for terminal sessions — the file browser uses its own
    /// SSH connections (via remoteCommand + mux) independent of terminal sessions.
    private func checkRemoteConnectivity() -> String? {
        guard appState.activeHost != nil else {
            return "No host configured."
        }
        return nil
    }

    /// Called when an SSH command fails (exit 255). Marks the mux as stale
    /// so the next command cleans up the socket and gets a fresh connection.
    private func handleSSHFailure() {
        guard let host = appState.activeHost, !host.isLocal else { return }
        appState.markMuxStale(for: host.id)
    }

    /// Run a remote script and, on a transient failure (exit 255 with no
    /// useful output), mark the mux stale and retry exactly once. The retry
    /// pays for the inevitable cold-start cost of the next ssh invocation
    /// after a stale-mux cleanup. Called from a background queue.
    private func runRemoteScriptWithRetry(_ script: String, timeout: TimeInterval = 30) -> ProcessResult {
        let (cmd, args) = appState.remoteCommand(script)
        let first = Self.runProcessWithStatus(cmd: cmd, args: args, timeout: timeout)
        let trimmed = first.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isTransient = first.exitCode == 255 && trimmed.isEmpty && !first.timedOut
        guard isTransient else { return first }

        // Mark stale and retry once with a fresh mux.
        DispatchQueue.main.sync { self.handleSSHFailure() }
        let (cmd2, args2) = appState.remoteCommand(script)
        return Self.runProcessWithStatus(cmd: cmd2, args: args2, timeout: timeout)
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
                let trimmed = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Auth failure surfaces as a recognizable string regardless of exit code
                if trimmed.contains("Permission denied (publickey") {
                    self.error = self.formatProcessError(result, action: "List \(path)")
                    self.handleSSHFailure()
                } else if let output = result.output, result.exitCode != 255 {
                    if trimmed.contains("No such file or directory")
                        || trimmed.hasPrefix("ls:")
                        || trimmed.contains("not a directory") {
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
                    self.error = self.formatProcessError(result, action: "List \(path)")
                    if result.exitCode == 255 { self.handleSSHFailure() }
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Run with retry: a stale mux frequently causes a transient
            // failure that the very next call cleans up automatically.
            let result = self?.runRemoteScriptWithRetry(script, timeout: 30)
                ?? ProcessResult(output: nil, exitCode: -1, timedOut: false)
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let self = self else { return }
                if result.exitCode == 0, let output = result.output {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines) == "__BINARY__" {
                        self.viewingFileName = name
                        self.isUnsupportedFile = true
                    } else {
                        self.fileContent = output
                        self.viewingFileName = name
                    }
                } else if let output = result.output,
                          !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          result.exitCode != 255 {
                    // Non-zero exit but real output: it's the remote command's
                    // own error (file not found, permission denied, etc).
                    // Show it as the file content rather than the error so the
                    // user sees the diagnostic in the file panel.
                    self.fileContent = output
                    self.viewingFileName = name
                } else {
                    self.error = self.formatProcessError(result, action: "Read \(name)")
                }
            }
        }
    }

    private func readImageFile(path escaped: String, name: String) {
        // Base64-encode the image and transfer as text
        let script = "base64 < \(escaped) 2>&1"
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runProcessWithStatus(cmd: cmd, args: args, timeout: 30)
            DispatchQueue.main.async {
                self?.isLoading = false
                guard let self = self else { return }
                if result.exitCode != 0 && result.exitCode != -1 {
                    self.error = self.formatProcessError(result, action: "Read image \(name)")
                    if result.exitCode == 255 { self.handleSSHFailure() }
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
        let timedOut: Bool
    }

    static func runProcess(cmd: String, args: [String]) -> String? {
        let result = runProcessWithStatus(cmd: cmd, args: args)
        return result.output
    }

    static func runProcessWithStatus(cmd: String, args: [String], timeout: TimeInterval = 10) -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Track whether OUR timer killed the process so callers can
            // distinguish a timeout from a remote-side error of the same code.
            let timedOutFlag = TimeoutFlag()
            let killTimer = DispatchSource.makeTimerSource(queue: .global())
            killTimer.schedule(deadline: .now() + timeout)
            killTimer.setEventHandler {
                if process.isRunning {
                    timedOutFlag.tripped = true
                    process.terminate()
                }
            }
            killTimer.resume()

            process.waitUntilExit()
            killTimer.cancel()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return ProcessResult(output: output, exitCode: process.terminationStatus, timedOut: timedOutFlag.tripped)
        } catch {
            return ProcessResult(output: nil, exitCode: -1, timedOut: false)
        }
    }

    /// Tiny boxed flag so the kill-timer closure can write to it from another queue.
    private final class TimeoutFlag {
        var tripped: Bool = false
    }

    /// Build a user-facing error message from a failed ProcessResult. Prefers
    /// the captured stdout/stderr (which contains the real failure detail)
    /// over a generic message. Only claims "SSH connection failed" when
    /// there's literally no output to show — and even then names what we
    /// actually know (the exit code) so the user has something to act on.
    private func formatProcessError(_ result: ProcessResult, action: String) -> String {
        let host = appState.activeHost?.label ?? "remote host"
        if result.timedOut {
            return "\(action) timed out on \(host) (>10s). Try again."
        }
        let trimmed = result.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            // Show the real error. Cap length so a runaway stderr doesn't
            // overwhelm the panel.
            let snippet = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
            return "\(action) failed: \(snippet)"
        }
        if result.exitCode == 255 {
            return "\(action) failed: ssh exit 255 to \(host) (no output). Retry usually works."
        }
        return "\(action) failed: exit code \(result.exitCode), no output."
    }

    /// Parse ls output.
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

    /// Start search.
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

    /// Cancel search.
    public func cancelSearch() {
        if let process = searchProcess, process.isRunning {
            process.terminate()
        }
        searchProcess = nil
        isSearching = false
    }

    /// Clear search.
    public func clearSearch() {
        cancelSearch()
        searchQuery = ""
        searchResults.clear()
        isSearchActive = false
    }

    // MARK: - Upload

    @Published public var uploadStatus: String?
    @Published public var isUploading = false

    /// Upload files.
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

    /// Download entry.
    public func downloadEntry(_ entry: RemoteEntry) {
        guard let current = currentPath else { return }
        let fullPath = current.hasSuffix("/") ? "\(current)\(entry.name)" : "\(current)/\(entry.name)"
        downloadPath(fullPath, isDirectory: entry.isDirectory)
    }

    /// Download path.
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
