import Foundation
import Combine


public struct RemoteEntry: Identifiable, Comparable {
    public let id = UUID()
    public let name: String
    public let isDirectory: Bool
    public let size: String
    public let modified: String

    public init(name: String, isDirectory: Bool, size: String, modified: String) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    public static func < (lhs: RemoteEntry, rhs: RemoteEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Search Tree Model

public class SearchTreeNode: Identifiable, ObservableObject {
    public let id = UUID()
    public let name: String
    public let fullPath: String
    public let isDirectory: Bool
    @Published public var children: [SearchTreeNode] = []
    @Published public var isExpanded: Bool = true

    public init(name: String, fullPath: String, isDirectory: Bool) {
        self.name = name
        self.fullPath = fullPath
        self.isDirectory = isDirectory
    }
}

public class SearchResultTree: ObservableObject {
    @Published public var roots: [SearchTreeNode] = []
    @Published public var resultCount: Int = 0
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

    public func clear() {
        roots = []
        resultCount = 0
    }
}

public struct SavedFolder: Codable, Identifiable, Equatable {
    public var id: String { "\(hostID.uuidString):\(path)" }
    public let path: String
    public let hostID: UUID

    public init(path: String, hostID: UUID) {
        self.path = path
        self.hostID = hostID
    }
}

public struct RecentFile: Identifiable, Equatable, Codable {
    public var id: String { "\(hostID.uuidString):\(path)" }
    public let path: String
    public let name: String
    public let hostID: UUID

    public init(path: String, name: String, hostID: UUID) {
        self.path = path
        self.name = name
        self.hostID = hostID
    }
}
