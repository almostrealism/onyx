import SwiftUI
import Combine

// MARK: - Views

struct GitLandingView: View {
    let status: GitRepoStatus
    let accentColor: Color
    @ObservedObject var gitManager: GitManager
    /// Called to track a file as recently opened (path, name)
    var onTrackFile: ((String, String) -> Void)?
    /// Called to navigate to and view a file (path, name) — for untracked files
    var onViewFile: ((String, String) -> Void)?
    /// Called to show a dependency graph diagram
    var onShowDepGraph: (() -> Void)?
    /// Status text for dependency analysis
    var depsStatus: String?

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

                    // Dependency graph button (for repos with changes)
                    if !status.isClean, let showGraph = onShowDepGraph {
                        if let status = depsStatus {
                            Text(status)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(accentColor.opacity(0.6))
                        } else {
                            Button(action: showGraph) {
                                HStack(spacing: 3) {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                        .font(.system(size: 9))
                                    Text("Deps")
                                        .font(.system(size: 9, design: .monospaced))
                                }
                                .foregroundColor(accentColor.opacity(0.5))
                            }
                            .buttonStyle(.plain)
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
                                            .onTapGesture {
                                                notifyOpenFile(file)
                                                gitManager.fetchFileDiff(file)
                                            }
                                    }
                                }

                                if !status.unstagedFiles.isEmpty {
                                    GitSectionHeader(title: "UNSTAGED", count: status.unstagedFiles.count, color: Color(hex: "FFD06B"))
                                    ForEach(status.unstagedFiles) { file in
                                        GitFileRow(file: file, showDiffIcon: true)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                notifyOpenFile(file)
                                                gitManager.fetchFileDiff(file)
                                            }
                                    }
                                }

                                if !status.untrackedFiles.isEmpty {
                                    GitSectionHeader(title: "UNTRACKED", count: status.untrackedFiles.count, color: .gray.opacity(0.5))
                                    ForEach(status.untrackedFiles) { file in
                                        GitFileRow(file: file, showDiffIcon: false)
                                            .contentShape(Rectangle())
                                            .onTapGesture { notifyOpenFile(file, viewFile: true) }
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

    /// Resolve a git-relative file path and notify for recent file tracking / navigation
    private func notifyOpenFile(_ file: GitChangedFile, viewFile: Bool = false) {
        guard let repoPath = gitManager.currentRepoPath else { return }
        let fullPath = repoPath.hasSuffix("/") ? repoPath + file.path : repoPath + "/" + file.path
        let name = (file.path as NSString).lastPathComponent
        onTrackFile?(fullPath, name)
        if viewFile {
            onViewFile?(fullPath, name)
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
