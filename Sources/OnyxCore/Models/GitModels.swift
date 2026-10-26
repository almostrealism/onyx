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

    public var label: String {
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

    public func color(for area: GitFileArea) -> Color {
        switch (self, area) {
        case (_, .staged): return Color.onyxGreen
        case (.deleted, _): return Color.onyxRed
        case (.untracked, _): return .gray.opacity(0.5)
        case (_, .unstaged): return Color.onyxAmber
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

    public init(path: String, status: GitFileStatus, area: GitFileArea) {
        self.path = path
        self.status = status
        self.area = area
    }
}

/// GitDiffStats.
public struct GitDiffStats {
    /// Files changed.
    public let filesChanged: Int
    /// Insertions.
    public let insertions: Int
    /// Deletions.
    public let deletions: Int

    public init(filesChanged: Int, insertions: Int, deletions: Int) {
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
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

    public init(branch: String, isDetachedHead: Bool, changedFiles: [GitChangedFile], diffStats: GitDiffStats?) {
        self.branch = branch
        self.isDetachedHead = isDetachedHead
        self.changedFiles = changedFiles
        self.diffStats = diffStats
    }

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

    public init(id: String, hash: String, message: String, author: String, date: String) {
        self.id = id
        self.hash = hash
        self.message = message
        self.author = author
        self.date = date
    }
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

    public init(hash: String, message: String, author: String, date: String, diff: String) {
        self.hash = hash
        self.message = message
        self.author = author
        self.date = date
        self.diff = diff
    }
}
