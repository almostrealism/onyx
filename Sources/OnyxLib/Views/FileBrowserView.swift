import SwiftUI
import UniformTypeIdentifiers
import AppKit

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
                                    },
                                    onShowDepGraph: {
                                        guard let repoPath = browser.gitManager.currentRepoPath else { return }
                                        browser.analyzeDependencies(repoPath: repoPath, appState: appState)
                                    },
                                    depsStatus: browser.depsStatus
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
    var hostLabel: String?
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
    var onDownload: (() -> Void)?
    var onViewDiff: (() -> Void)?

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

struct ImageContentView: View {
    let fileName: String
    let imageData: Data
    let accentColor: Color
    let onClose: () -> Void
    var onDownload: (() -> Void)?

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
    var onDownload: (() -> Void)?

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

// MARK: - Full-Window File Browser (⌘⇧O)

/// Full-window file browser with three columns: folder sidebar,
/// directory listing / search results, and file content side by side.
/// Unlike the right-panel mode where viewing a file replaces the
/// directory listing, the full-window mode keeps the tree visible so
/// you can navigate and read files simultaneously.
struct FullFileBrowserView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var browser: FileBrowserManager

    init(appState: AppState) {
        self.appState = appState
        self.browser = appState.fileBrowserManager
    }

    /// Whether the right pane (file content) has something to show.
    private var hasFileContent: Bool {
        browser.fileContent != nil || browser.imageData != nil || browser.isUnsupportedFile
            || browser.gitManager.showLog
    }

    var body: some View {
        ZStack {
            Color(nsColor: NSColor(white: 0.04, alpha: 0.98))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundColor(appState.accentColor)
                    Text("FILE BROWSER")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    Text("⌘⇧O close  ·  ⌘O panel mode")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                    Button(action: { appState.showFullFileBrowser = false; appState.recalculateFocus() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.1))

                // Three-column layout
                HStack(spacing: 0) {
                    // Column 1: Folder sidebar
                    FolderSidebar(appState: appState, browser: browser)
                        .frame(width: 200)

                    Divider().background(Color.white.opacity(0.1))

                    // Column 2: Directory listing / search / git landing
                    VStack(spacing: 0) {
                        NavigationBar(appState: appState, browser: browser)
                        Divider().background(Color.white.opacity(0.1))

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
                                .padding()
                            Spacer()
                        } else if browser.isSearchActive || browser.wasSearchActiveBeforeFile {
                            // Show search results even when a file is open (the
                            // file appears in the right column in full mode)
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
                                        },
                                        onShowDepGraph: {
                                            guard let repoPath = browser.gitManager.currentRepoPath else { return }
                                            browser.analyzeDependencies(repoPath: repoPath, appState: appState)
                                        },
                                        depsStatus: browser.depsStatus
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
                            }
                            Spacer()
                        }
                    }
                    .frame(minWidth: 250)
                    .frame(maxWidth: hasFileContent ? .infinity : .infinity)

                    // Column 3: File content (only when a file is selected)
                    if hasFileContent {
                        Divider().background(Color.white.opacity(0.1))

                        VStack(spacing: 0) {
                            if let data = browser.imageData {
                                ImageContentView(
                                    fileName: browser.viewingFileName ?? "image",
                                    imageData: data,
                                    accentColor: appState.accentColor,
                                    onClose: { browser.closeFile() },
                                    onDownload: { downloadCurrentFile() }
                                )
                            } else if browser.isUnsupportedFile {
                                UnsupportedFileView(
                                    fileName: browser.viewingFileName ?? "file",
                                    accentColor: appState.accentColor,
                                    onClose: { browser.closeFile() },
                                    onDownload: { downloadCurrentFile() }
                                )
                            } else if let content = browser.fileContent {
                                FileContentView(
                                    fileName: browser.viewingFileName ?? "file",
                                    content: content,
                                    accentColor: appState.accentColor,
                                    onClose: { browser.closeFile() },
                                    onDownload: { downloadCurrentFile() },
                                    onViewDiff: browser.gitChangedFileForViewing().map { file in
                                        { browser.gitManager.fetchFileDiff(file) }
                                    }
                                )
                            } else if browser.gitManager.showLog {
                                GitLogView(gitManager: browser.gitManager, accentColor: appState.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func downloadCurrentFile() {
        if let path = browser.currentPath, let name = browser.viewingFileName {
            let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
            browser.downloadPath(fullPath, isDirectory: false)
        }
    }
}

// MARK: - File Preview Overlay (Space bar)

/// Full-screen overlay that shows file content over everything else.
/// Triggered by pressing Space while viewing a file in the file browser.
/// Press Space or Escape to dismiss.
struct FilePreviewOverlay: View {
    let fileName: String
    let content: String
    let accentColor: Color
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: iconForFile(fileName))
                        .font(.system(size: 13))
                        .foregroundColor(accentColor)
                    Text(fileName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text("Space or Esc to close")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)

                Divider().background(accentColor.opacity(0.3))

                // File content with syntax highlighting
                ScrollView {
                    Text(attributedContent)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        }
    }

    private var attributedContent: AttributedString {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return SyntaxHighlighter.highlight(content, fileName: fileName)
    }
}
