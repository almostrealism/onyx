//
// FileTree.swift
//
// Responsibility: The file browser's tree view as rows: which folders are
//                 open, what's in them, and the flat, indented list that
//                 results.
// Scope: Pure data. FileBrowserManager loads each folder's entries when
//        it's first opened; this only arranges what's been loaded.
//

import Foundation

public struct FileTree: Equatable {
    /// Folders shown open, by full path.
    public var expanded: Set<String> = []
    /// Each opened folder's entries, by full path, once loaded.
    public var children: [String: [RemoteEntry]] = [:]
    /// Folders whose entries are being fetched.
    public var loading: Set<String> = []
    /// Folders that couldn't be listed, and why.
    public var failures: [String: String] = [:]

    public init() {}

    /// One line of the tree.
    public struct Row: Identifiable, Equatable {
        public let path: String
        public let entry: RemoteEntry
        public let depth: Int
        public let isExpanded: Bool
        public let isLoading: Bool
        public var id: String { path }
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// The rows to draw: `roots` (the folder being shown), each open
    /// folder's entries beneath it, indented. A folder still loading is
    /// open with nothing under it yet.
    public func rows(roots: [RemoteEntry], in rootPath: String) -> [Row] {
        var out: [Row] = []
        func walk(_ entries: [RemoteEntry], parent: String, depth: Int) {
            for entry in entries {
                let path = Self.join(parent, entry.name)
                let open = entry.isDirectory && expanded.contains(path)
                out.append(Row(path: path, entry: entry, depth: depth,
                               isExpanded: open, isLoading: loading.contains(path)))
                if open, let kids = children[path] {
                    walk(kids, parent: path, depth: depth + 1)
                }
            }
        }
        walk(roots, parent: rootPath, depth: 0)
        return out
    }

    /// Close an open folder or open a closed one. Returns true when the
    /// folder was opened and its entries still need fetching.
    public mutating func toggle(_ path: String) -> Bool {
        if expanded.contains(path) {
            expanded.remove(path)
            return false
        }
        expanded.insert(path)
        guard children[path] == nil, !loading.contains(path) else { return false }
        loading.insert(path)
        failures[path] = nil
        return true
    }

    public mutating func loaded(_ path: String, _ entries: [RemoteEntry]) {
        loading.remove(path)
        children[path] = entries
    }

    public mutating func failed(_ path: String, _ reason: String) {
        loading.remove(path)
        failures[path] = reason
        // Closed again, so the next click retries.
        expanded.remove(path)
    }
}
