import Foundation
import SwiftUI

// MARK: - Data Models

/// GitFileStatus.
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

/// GitFileArea.
public enum GitFileArea {
    case staged
    case unstaged
    case untracked
}

/// GitChangedFile.
public struct GitChangedFile: Identifiable {
    /// Id.
    public let id = UUID()
    /// Path.
    public let path: String
    /// Status.
    public let status: GitFileStatus
    /// Area.
    public let area: GitFileArea
}

/// GitDiffStats.
public struct GitDiffStats {
    /// Files changed.
    public let filesChanged: Int
    /// Insertions.
    public let insertions: Int
    /// Deletions.
    public let deletions: Int
}

/// GitRepoStatus.
public struct GitRepoStatus {
    /// Branch.
    public let branch: String
    /// Is detached head.
    public let isDetachedHead: Bool
    /// Changed files.
    public let changedFiles: [GitChangedFile]
    /// Diff stats.
    public let diffStats: GitDiffStats?

    /// Staged files.
    public var stagedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .staged } }
    /// Unstaged files.
    public var unstagedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .unstaged } }
    /// Untracked files.
    public var untrackedFiles: [GitChangedFile] { changedFiles.filter { $0.area == .untracked } }
    /// Is clean.
    public var isClean: Bool { changedFiles.isEmpty }
}

/// GitLogEntry.
public struct GitLogEntry: Identifiable {
    /// Id.
    public let id: String     // commit hash (short)
    /// Hash.
    public let hash: String
    /// Message.
    public let message: String
    /// Author.
    public let author: String
    /// Date.
    public let date: String   // relative or short date
}

/// GitCommitDetail.
public struct GitCommitDetail {
    /// Hash.
    public let hash: String
    /// Message.
    public let message: String
    /// Author.
    public let author: String
    /// Date.
    public let date: String
    /// Diff.
    public let diff: String   // full diff output
}
