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

// MARK: - GitManager

public class GitManager: ObservableObject {
    @Published public var repoStatus: GitRepoStatus?
    @Published public var isGitRepo = false
    @Published public var isLoading = false

    private let appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public func checkAndLoad(path: String) {
        isLoading = true

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    }
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

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !status.stagedFiles.isEmpty {
                            GitSectionHeader(title: "STAGED", count: status.stagedFiles.count, color: Color(hex: "6BFF8E"))
                            ForEach(status.stagedFiles) { file in
                                GitFileRow(file: file)
                            }
                        }

                        if !status.unstagedFiles.isEmpty {
                            GitSectionHeader(title: "UNSTAGED", count: status.unstagedFiles.count, color: Color(hex: "FFD06B"))
                            ForEach(status.unstagedFiles) { file in
                                GitFileRow(file: file)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
