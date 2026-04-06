import Foundation
import SwiftUI

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
