import SwiftUI
import Combine

// MARK: - Data Models

public enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case unmerged = "U"

    var label: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "?"
        case .unmerged: return "U"
        }
    }

    func color(for area: GitFileArea) -> Color {
        switch (self, area) {
        case (_, .staged): return Color(hex: "6BFF8E")
        case (.deleted, _): return Color(hex: "FF6B6B")
        case (.untracked, _): return .gray.opacity(0.5)
        case (_, .unstaged): return Color(hex: "FFD06B")
        default: return .gray
        }
    }
}

public enum GitFileArea {
    case staged
    case unstaged
    case untracked
}

public struct GitChangedFile: Identifiable {
    public let id = UUID()
    public let path: String
    public let status: GitFileStatus
    public let area: GitFileArea
}

public struct GitDiffStats {
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
}

public struct GitRepoStatus {
    public let branch: String
    public let isDetachedHead: Bool
    public let changedFiles: [GitChangedFile]
    public let diffStats: GitDiffStats?

    public var stagedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .staged } }
    public var unstagedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .unstaged } }
    public var untrackedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .untracked } }
    public var isClean: Bool { changedFiles.isEmpty }
}

public struct GitLogEntry: Identifiable {
    public let id: String     // commit hash (short)
    public let hash: String
    public let message: String
    public let author: String
    public let date: String   // relative or short date
}

public struct GitCommitDetail {
    public let hash: String
    public let message: String
    public let author: String
    public let date: String
    public let diff: String   // full diff output
}

// MARK: - GitManager

public class GitManager: ObservableObject {
    @Published public var repoStatus: GitRepoStatus?
    @Published public var isGitRepo = false
    @Published public var isLoading = false
    @Published public var logEntries: [GitLogEntry] = []
    @Published public var isLoadingLog = false
    @Published public var showLog = false
    @Published public var commitDetail: GitCommitDetail?
    @Published public var isLoadingCommit = false
    @Published public var fileDiff: String?
    @Published public var fileDiffTitle: String?
    @Published public var isLoadingDiff = false

    private let appState: AppState
    private var currentRepoPath: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public func checkAndLoad(path: String) {
        isLoading = true
        currentRepoPath = path

        let escaped = escapeForShell(path)
        // Single compound command with markers — one SSH round-trip
        let script = """
        git -C \(escaped) rev-parse --is-inside-work-tree 2>/dev/null && \
        echo "---GIT_BRANCH---" && \
        git -C \(escaped) branch --show-current 2>/dev/null && \
        echo "---GIT_HEAD---" && \
        git -C \(escaped) rev-parse --short HEAD 2>/dev/null && \
        echo "---GIT_STATUS---" && \
        git -C \(escaped) status --porcelain 2>/dev/null && \
        echo "---GIT_DIFF_STAT---" && \
        git -C \(escaped) diff --stat 2>/dev/null && \
        echo "---GIT_DIFF_CACHED_STAT---" && \
        git -C \(escaped) diff --cached --stat 2>/dev/null && \
        echo "---GIT_TOPLEVEL---" && \
        git -C \(escaped) rev-parse --show-toplevel 2>/dev/null
        """

        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                guard let output = output else {
                    self.isGitRepo = false
                    self.repoStatus = nil
                    return
                }
                self.parseOutput(output, currentPath: path)
            }
        }
    }

    public func clear() {
        isGitRepo = false
        repoStatus = nil
        logEntries = []
        showLog = false
        commitDetail = nil
        fileDiff = nil
        fileDiffTitle = nil
        currentRepoPath = nil
    }

    // MARK: - Git Log

    public func fetchLog(forFile filePath: String? = nil) {
        guard let repoPath = currentRepoPath else { return }
        isLoadingLog = true
        showLog = true
        commitDetail = nil

        let escaped = escapeForShell(repoPath)
        // Use %x00 as field separator, %x01 as record separator
        var script = "git -C \(escaped) log --pretty=format:'%h%x00%s%x00%an%x00%ar%x01' -50"
        if let file = filePath {
            let escapedFile = escapeForShell(file)
            script += " -- \(escapedFile)"
        }

        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingLog = false
                guard let output = output else {
                    self.logEntries = []
                    return
                }
                self.logEntries = self.parseLogOutput(output)
            }
        }
    }

    public func fetchCommitDetail(hash: String) {
        guard let repoPath = currentRepoPath else { return }
        isLoadingCommit = true

        let escaped = escapeForShell(repoPath)
        let script = """
        echo "---COMMIT_INFO---" && \
        git -C \(escaped) log -1 --pretty=format:'%H%n%s%n%an%n%ar' \(hash) 2>/dev/null && \
        echo "" && echo "---COMMIT_DIFF---" && \
        git -C \(escaped) diff-tree -p --stat \(hash) 2>/dev/null
        """

        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingCommit = false
                guard let output = output else { return }
                self.commitDetail = self.parseCommitDetail(output, hash: hash)
            }
        }
    }

    public func closeLog() {
        showLog = false
        commitDetail = nil
        logEntries = []
    }

    // MARK: - File Diff

    /// Fetch diff for a specific changed file
    public func fetchFileDiff(_ file: GitChangedFile) {
        guard let repoPath = currentRepoPath else { return }
        isLoadingDiff = true
        fileDiffTitle = file.path

        let escaped = escapeForShell(repoPath)
        let filePath = file.path.replacingOccurrences(of: "'", with: "'\\''")
        let script: String
        switch file.area {
        case .staged:
            script = "git -C \(escaped) diff --cached -- '\(filePath)' 2>/dev/null"
        case .unstaged, .untracked:
            script = "git -C \(escaped) diff -- '\(filePath)' 2>/dev/null"
        }

        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingDiff = false
                self.fileDiff = output ?? "No diff available"
            }
        }
    }

    /// Fetch full working diff (staged + unstaged combined)
    public func fetchFullDiff() {
        guard let repoPath = currentRepoPath else { return }
        isLoadingDiff = true
        fileDiffTitle = "All Changes"

        let escaped = escapeForShell(repoPath)
        // Show both staged and unstaged in one output
        let script = """
        echo "--- STAGED ---" && \
        git -C \(escaped) diff --cached 2>/dev/null && \
        echo "" && echo "--- UNSTAGED ---" && \
        git -C \(escaped) diff 2>/dev/null
        """

        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = FileBrowserManager.runProcess(cmd: cmd, args: args)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoadingDiff = false
                self.fileDiff = output ?? "No diff available"
            }
        }
    }

    public func closeDiff() {
        fileDiff = nil
        fileDiffTitle = nil
    }

    private func parseLogOutput(_ output: String) -> [GitLogEntry] {
        // Records separated by \x01, fields by \x00
        return output.components(separatedBy: "\u{01}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { record in
                let fields = record.components(separatedBy: "\u{00}")
                guard fields.count >= 4 else { return nil }
                let hash = fields[0].trimmingCharacters(in: .init(charactersIn: "'"))
                return GitLogEntry(
                    id: hash,
                    hash: hash,
                    message: fields[1],
                    author: fields[2],
                    date: fields[3]
                )
            }
    }

    private func parseCommitDetail(_ output: String, hash: String) -> GitCommitDetail? {
        let info = extractSection(output, start: "---COMMIT_INFO---", end: "---COMMIT_DIFF---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = extractSection(output, start: "---COMMIT_DIFF---", end: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = info.components(separatedBy: "\n")
        guard lines.count >= 4 else { return nil }

        return GitCommitDetail(
            hash: lines[0],
            message: lines[1],
            author: lines[2],
            date: lines[3],
            diff: diff
        )
    }

    // MARK: - Parsing

    private func parseOutput(_ output: String, currentPath: String) {
        // Check if git rev-parse succeeded (first line should be "true")
        guard output.contains("---GIT_BRANCH---") else {
            isGitRepo = false
            repoStatus = nil
            return
        }

        // Only show git landing at repo root
        let toplevel = extractSection(output, start: "---GIT_TOPLEVEL---", end: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = currentPath.hasSuffix("/") ? String(currentPath.dropLast()) : currentPath
        if !toplevel.isEmpty && toplevel != normalizedPath {
            isGitRepo = false
            repoStatus = nil
            return
        }

        isGitRepo = true

        let branchRaw = extractSection(output, start: "---GIT_BRANCH---", end: "---GIT_HEAD---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headRaw = extractSection(output, start: "---GIT_HEAD---", end: "---GIT_STATUS---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusRaw = extractSection(output, start: "---GIT_STATUS---", end: "---GIT_DIFF_STAT---")
        let diffRaw = extractSection(output, start: "---GIT_DIFF_STAT---", end: "---GIT_DIFF_CACHED_STAT---")
        let diffCachedRaw = extractSection(output, start: "---GIT_DIFF_CACHED_STAT---", end: "---GIT_TOPLEVEL---")

        let isDetached = branchRaw.isEmpty
        let branch = isDetached ? (headRaw.isEmpty ? "unknown" : headRaw) : branchRaw

        let changedFiles = parseGitStatusPorcelain(statusRaw)
        let diffStats = mergeDiffStats(
            parseDiffStat(diffRaw),
            parseDiffStat(diffCachedRaw)
        )

        repoStatus = GitRepoStatus(
            branch: branch,
            isDetachedHead: isDetached,
            changedFiles: changedFiles,
            diffStats: diffStats
        )
    }

    private func extractSection(_ output: String, start: String, end: String?) -> String {
        guard let startRange = output.range(of: start) else { return "" }
        let after = output[startRange.upperBound...]
        if let end = end, let endRange = after.range(of: end) {
            return String(after[..<endRange.lowerBound])
        }
        return String(after)
    }

    func parseGitStatusPorcelain(_ output: String) -> [GitChangedFile] {
        var files: [GitChangedFile] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r"))
            guard trimmed.count >= 3 else { continue }

            let indexChar = trimmed[trimmed.startIndex]
            let workChar = trimmed[trimmed.index(after: trimmed.startIndex)]
            let path = String(trimmed.dropFirst(3))

            guard !path.isEmpty else { continue }

            if indexChar == "?" {
                files.append(GitChangedFile(path: path, status: .untracked, area: .untracked))
                continue
            }

            if indexChar != " " {
                let status = GitFileStatus(rawValue: String(indexChar)) ?? .modified
                files.append(GitChangedFile(path: path, status: status, area: .staged))
            }
            if workChar != " " && workChar != "?" {
                let status = GitFileStatus(rawValue: String(workChar)) ?? .modified
                files.append(GitChangedFile(path: path, status: status, area: .unstaged))
            }
        }
        return files
    }

    func parseDiffStat(_ output: String) -> GitDiffStats? {
        // Last line of git diff --stat looks like: " 3 files changed, 45 insertions(+), 12 deletions(-)"
        let lines = output.components(separatedBy: "\n")
        guard let summary = lines.last(where: { $0.contains("changed") }) else { return nil }

        let filesChanged = extractNumber(from: summary, before: "file")
        let insertions = extractNumber(from: summary, before: "insertion")
        let deletions = extractNumber(from: summary, before: "deletion")

        guard filesChanged > 0 || insertions > 0 || deletions > 0 else { return nil }
        return GitDiffStats(filesChanged: filesChanged, insertions: insertions, deletions: deletions)
    }

    private func mergeDiffStats(_ a: GitDiffStats?, _ b: GitDiffStats?) -> GitDiffStats? {
        guard let a = a else { return b }
        guard let b = b else { return a }
        return GitDiffStats(
            filesChanged: a.filesChanged + b.filesChanged,
            insertions: a.insertions + b.insertions,
            deletions: a.deletions + b.deletions
        )
    }

    private func extractNumber(from text: String, before keyword: String) -> Int {
        guard let range = text.range(of: keyword) else { return 0 }
        let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        // Get last word before the keyword
        let parts = prefix.split(separator: " ")
        guard let last = parts.last, let num = Int(last) else { return 0 }
        return num
    }

    private func escapeForShell(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}

// MARK: - Views

struct GitLandingView: View {
    let status: GitRepoStatus
    let accentColor: Color
    @ObservedObject var gitManager: GitManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Check if we're showing a diff
            if let diff = gitManager.fileDiff {
                GitDiffView(
                    title: gitManager.fileDiffTitle ?? "Diff",
                    diff: diff,
                    accentColor: accentColor,
                    onClose: { gitManager.closeDiff() }
                )
            } else {
                // Branch + summary header
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundColor(accentColor)

                    Text(status.branch)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(accentColor)

                    if status.isDetachedHead {
                        Text("DETACHED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "FFD06B"))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(hex: "FFD06B").opacity(0.15))
                            .cornerRadius(2)
                    }

                    Spacer()

                    if let stats = status.diffStats {
                        // Tap to view full diff
                        Button(action: { gitManager.fetchFullDiff() }) {
                            HStack(spacing: 6) {
                                if stats.insertions > 0 {
                                    Text("+\(stats.insertions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color(hex: "6BFF8E"))
                                }
                                if stats.deletions > 0 {
                                    Text("-\(stats.deletions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color(hex: "FF6B6B"))
                                }
                                Text("~\(stats.filesChanged)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.5))

                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 9))
                                    .foregroundColor(accentColor.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if status.isClean {
                        Text("clean")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(hex: "6BFF8E").opacity(0.6))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.03))

                // Changed files sections
                if !status.isClean {
                    Divider().background(Color.white.opacity(0.06))

                    if gitManager.isLoadingDiff {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6).colorScheme(.dark)
                            Text("Loading diff...")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                        .padding(12)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                if !status.stagedFiles.isEmpty {
                                    GitSectionHeader(title: "STAGED", count: status.stagedFiles.count, color: Color(hex: "6BFF8E"))
                                    ForEach(status.stagedFiles) { file in
                                        GitFileRow(file: file, showDiffIcon: true)
                                            .contentShape(Rectangle())
                                            .onTapGesture { gitManager.fetchFileDiff(file) }
                                    }
                                }

                                if !status.unstagedFiles.isEmpty {
                                    GitSectionHeader(title: "UNSTAGED", count: status.unstagedFiles.count, color: Color(hex: "FFD06B"))
                                    ForEach(status.unstagedFiles) { file in
                                        GitFileRow(file: file, showDiffIcon: true)
                                            .contentShape(Rectangle())
                                            .onTapGesture { gitManager.fetchFileDiff(file) }
                                    }
                                }

                                if !status.untrackedFiles.isEmpty {
                                    GitSectionHeader(title: "UNTRACKED", count: status.untrackedFiles.count, color: .gray.opacity(0.5))
                                    ForEach(status.untrackedFiles) { file in
                                        GitFileRow(file: file)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }
        }
    }
}

private struct GitSectionHeader: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color.opacity(0.7))
                .tracking(1)

            Text("\(count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(color.opacity(0.4))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct GitFileRow: View {
    let file: GitChangedFile
    var showDiffIcon: Bool = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(file.status.color(for: file.area))
                .frame(width: 14)

            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if showDiffIcon {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundColor(.gray.opacity(isHovered ? 0.6 : 0.25))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(isHovered && showDiffIcon ? Color.white.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Git Diff View

struct GitDiffView: View {
    let title: String
    let diff: String
    let accentColor: Color
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(accentColor.opacity(0.6))

                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            // Diff content with line coloring
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(diffLineColor(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 0.5)
                            .background(diffLineBackground(line))
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
        }
    }

    private func diffLineColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return .white.opacity(0.6)
        }
        if line.hasPrefix("+") { return Color(hex: "6BFF8E") }
        if line.hasPrefix("-") { return Color(hex: "FF6B6B") }
        if line.hasPrefix("@@") { return Color(hex: "66CCFF") }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") { return .white.opacity(0.4) }
        return .white.opacity(0.7)
    }

    private func diffLineBackground(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(hex: "6BFF8E").opacity(0.06) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(hex: "FF6B6B").opacity(0.06) }
        if line.hasPrefix("@@") { return Color(hex: "66CCFF").opacity(0.04) }
        return .clear
    }
}

// MARK: - Git Log View

struct GitLogView: View {
    @ObservedObject var gitManager: GitManager
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(accentColor)

                Text("HISTORY")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)
                    .tracking(2)

                Spacer()

                if !gitManager.logEntries.isEmpty {
                    Text("\(gitManager.logEntries.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }

                Button(action: { gitManager.closeLog() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.gray.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))

            Divider().background(Color.white.opacity(0.06))

            if gitManager.isLoadingLog {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7).colorScheme(.dark)
                    Text("Loading history...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                }
                Spacer()
            } else if let detail = gitManager.commitDetail {
                GitCommitDetailView(detail: detail, accentColor: accentColor, onBack: {
                    gitManager.commitDetail = nil
                })
            } else if gitManager.logEntries.isEmpty {
                Spacer()
                Text("No commits")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(gitManager.logEntries) { entry in
                            GitLogRow(entry: entry, accentColor: accentColor)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    gitManager.fetchCommitDetail(hash: entry.hash)
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct GitLogRow: View {
    let entry: GitLogEntry
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.hash)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(accentColor.opacity(0.7))
                .frame(width: 56, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()

            Text(entry.date)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

private struct GitCommitDetailView: View {
    let detail: GitCommitDetail
    let accentColor: Color
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Commit info header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)

                Text(String(detail.hash.prefix(8)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)

                Text(detail.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.4))
                    Text(detail.author)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.5))
                }
                Text(detail.date)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider().background(Color.white.opacity(0.06))

            // Diff content
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail.diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.75))
                        .textSelection(.enabled)
                        .padding(12)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }
}
