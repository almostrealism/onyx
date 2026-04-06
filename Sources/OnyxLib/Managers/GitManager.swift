import Foundation
import Combine
import SwiftUI

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
    public internal(set) var currentRepoPath: String?

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
