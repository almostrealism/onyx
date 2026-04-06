import Foundation
import Combine


/// RemoteEntry.
public struct RemoteEntry: Identifiable, Comparable {
    /// Id.
    public let id = UUID()
    /// Name.
    public let name: String
    /// Is directory.
    public let isDirectory: Bool
    /// Size.
    public let size: String
    /// Modified.
    public let modified: String

    /// Create a new instance.
    public init(name: String, isDirectory: Bool, size: String, modified: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// .
    public static func < (lhs: RemoteEntry, rhs: RemoteEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Search Tree Model

/// SearchTreeNode.
public class SearchTreeNode: Identifiable, ObservableObject {
    /// Id.
    public let id = UUID()
    /// Name.
    public let name: String
    /// Full path.
    public let fullPath: String
    /// Is directory.
    public let isDirectory: Bool
    @Published public var children: [SearchTreeNode] = []
    @Published public var isExpanded: Bool = true

    /// Create a new instance.
    public init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }
}

/// SearchResultTree.
public class SearchResultTree: ObservableObject {
    @Published public var roots: [SearchTreeNode] = []
    @Published public var resultCount: Int = 0
    /// Max results.
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

    /// Clear.
    public func clear() {
        roots = []
        resultCount = 0
    }
}

/// SavedFolder.
public struct SavedFolder: Codable, Identifiable, Equatable {
    /// Id.
    public var id: String { "\(hostID.uuidString):\(path)" }
    /// Path.
    public let path: String
    /// Host id.
    public let hostID: UUID

    /// Create a new instance.
    public init(path: String, hostID: UUID) {
        self.path = path
        self.hostID = hostID
    }
}

/// RecentFile.
public struct RecentFile: Identifiable, Equatable, Codable {
    /// Id.
    public var id: String { "\(hostID.uuidString):\(path)" }
    /// Path.
    public let path: String
    /// Name.
    public let name: String
    /// Host id.
    public let hostID: UUID

    /// Create a new instance.
    public init(path: String, name: String, hostID: UUID) {
        self.path = path
        self.name = name
        self.hostID = hostID
    }
}
