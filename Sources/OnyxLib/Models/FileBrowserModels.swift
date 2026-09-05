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

    /// Create a new instance.
    public init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }

    /// Flatten a search tree into the rows that should be on screen.
    ///
    /// This exists because rendering the tree recursively — a ForEach of
    /// child views, each with its own nested ForEach — hung the app for
    /// 30 seconds on a large result set. A LazyVStack can only be lazy
    /// about its DIRECT children, so with the recursion nested inside it
    /// SwiftUI had to walk and place every node in the tree on every
    /// layout pass, instantiating fresh generic metadata at each level of
    /// nesting. Flattened, the lazy stack sees one uniform row type and
    /// only builds the rows actually visible.
    ///
    /// Iterative rather than recursive: a deep tree shouldn't be able to
    /// exhaust the stack while we're fixing a performance bug caused by
    /// depth.
    public static func visibleRows(roots: [SearchTreeNode],
                                   collapsed: Set<UUID>) -> [(node: SearchTreeNode, depth: Int)] {
        var rows: [(node: SearchTreeNode, depth: Int)] = []
        // Reversed so the explicit stack pops in the original order.
        var pending: [(SearchTreeNode, Int)] = roots.reversed().map { ($0, 0) }
        while let (node, depth) = pending.popLast() {
            rows.append((node, depth))
            guard node.isDirectory, !collapsed.contains(node.id) else { continue }
            pending.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
        }
        return rows
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
        var parentNode: SearchTreeNode?

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
