//
// FavoriteTree.swift
//
// Responsibility: Turn a flat list of favorite folder paths into the
//                 nested forest the treemap renders.
// Scope: Models layer. Pure functions on strings — no UI, no I/O.
//
// Two problems, one structure:
//
//   1. Ambiguity. /Users/agent0/Projects and /Users/agent1/Projects both
//      render as "Projects". Rather than showing longer paths (which
//      don't fit in a block button), we introduce the parents as
//      *implicit* nodes — boxes the user never added — so the two
//      "Projects" cells sit inside visibly different containers.
//
//   2. Redundancy. Adding /Users/agent1 and /Users/agent1/Projects used
//      to produce two unrelated buttons. The second is nested inside the
//      first, which is what the paths already say.
//

import Foundation

/// One box in the favorites treemap.
public struct FavoriteTreeNode: Identifiable, Equatable {
    /// Absolute path this box represents.
    public let path: String
    /// True when the user actually saved this folder. Implicit nodes
    /// (added only to resolve ambiguity) are false: they're containers,
    /// and removing them would mean nothing.
    public let isFavorite: Bool
    /// Nested favorites, already disambiguated among themselves.
    public var children: [FavoriteTreeNode]

    public var id: String { path }

    /// Display name — the last path component, or "/" for the root.
    public var label: String {
        FavoriteTreeNode.label(for: path)
    }

    /// How many *saved* favorites this box contains, itself included.
    /// Drives treemap area, so a folder holding six favorites reads as
    /// bigger than one holding a single favorite. Never zero: an implicit
    /// node with no favorite descendants would otherwise vanish.
    public var weight: Int {
        max(1, (isFavorite ? 1 : 0) + children.reduce(0) { $0 + $1.weight })
    }

    public init(path: String, isFavorite: Bool, children: [FavoriteTreeNode] = []) {
        self.path = path
        self.isFavorite = isFavorite
        self.children = children
    }

    static func label(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

public enum FavoriteTree {

    /// Build the forest for one host's favorites.
    ///
    /// Order is stable: nodes come out sorted by path, so the treemap
    /// doesn't reshuffle between renders.
    public static func build(paths: [String]) -> [FavoriteTreeNode] {
        let normalized = Array(Set(paths.map(normalize))).filter { !$0.isEmpty }.sorted()
        guard !normalized.isEmpty else { return [] }

        // 1. Nest each favorite under its DEEPEST favorite ancestor.
        var childrenOf: [String: [String]] = [:]
        var roots: [String] = []
        for path in normalized {
            let ancestor = normalized
                .filter { isStrictAncestor($0, of: path) }
                .max(by: { $0.count < $1.count })
            if let ancestor {
                childrenOf[ancestor, default: []].append(path)
            } else {
                roots.append(path)
            }
        }

        func node(_ path: String) -> FavoriteTreeNode {
            FavoriteTreeNode(path: path,
                             isFavorite: true,
                             children: (childrenOf[path] ?? []).sorted().map(node))
        }

        // 2. Resolve same-label collisions at every level.
        return disambiguate(roots.sorted().map(node), within: nil)
    }

    /// Labels in use anywhere in the forest, with counts.
    static func labelCounts(_ nodes: [FavoriteTreeNode]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for node in flatten(nodes) { counts[node.label, default: 0] += 1 }
        return counts
    }

    /// Strip trailing slashes so "/a/b" and "/a/b/" are one folder. The
    /// filesystem root stays "/".
    public static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Is `candidate` a strict parent-or-higher of `path`? Compares whole
    /// components, so /Users/ag is not an ancestor of /Users/agent1.
    static func isStrictAncestor(_ candidate: String, of path: String) -> Bool {
        guard candidate != path else { return false }
        if candidate == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(candidate + "/")
    }

    /// Parent directory, or nil at the root.
    static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { return nil }
        return normalize(parent)
    }

    /// Make every label in this sibling set unique by pulling colliding
    /// nodes up into their parent directory, which becomes an implicit
    /// container. Repeats until the labels differ (two "Projects" under
    /// two different "src" folders need two levels), and recurses into
    /// each node's own children.
    ///
    /// `container` is the path the set lives inside — nodes may never be
    /// lifted out of it, or a child would escape its parent box.
    static func disambiguate(_ nodes: [FavoriteTreeNode],
                             within container: String?) -> [FavoriteTreeNode] {
        var current = nodes
        // Bounded: each pass moves at least one node strictly closer to
        // the container, and the loop stops when nothing can lift.
        for _ in 0..<64 {
            var counts: [String: Int] = [:]
            if container == nil {
                // Top level boxes have no container to identify them, so
                // they collide with the SAME LABEL ANYWHERE — a bare
                // "Projects" floating next to "agent1 › Projects" is the
                // ambiguity we're here to remove. Nested boxes only
                // compete with their own siblings; their container
                // already tells them apart.
                counts = labelCounts(current)
            } else {
                for n in current { counts[n.label, default: 0] += 1 }
            }
            let colliding = Set(counts.filter { $0.value > 1 }.keys)
            if colliding.isEmpty { break }

            var merged: [String: FavoriteTreeNode] = [:]
            var order: [String] = []
            var lifted = false

            func absorb(_ node: FavoriteTreeNode) {
                if let existing = merged[node.path] {
                    merged[node.path] = FavoriteTreeNode(
                        path: existing.path,
                        // A real favorite always wins over an implicit box
                        // of the same path.
                        isFavorite: existing.isFavorite || node.isFavorite,
                        children: (existing.children + node.children).sorted { $0.path < $1.path })
                } else {
                    merged[node.path] = node
                    order.append(node.path)
                }
            }

            for node in current {
                guard colliding.contains(node.label),
                      let parentPath = parent(of: node.path),
                      canLift(to: parentPath, within: container) else {
                    absorb(node)
                    continue
                }
                lifted = true
                absorb(FavoriteTreeNode(path: parentPath, isFavorite: false, children: [node]))
            }

            current = order.compactMap { merged[$0] }
            // Nothing could move (every collider sits directly inside the
            // container) — stop rather than spin. The view falls back to
            // showing more of the path for these.
            if !lifted { break }
        }

        return current
            .map { node in
                FavoriteTreeNode(path: node.path,
                                 isFavorite: node.isFavorite,
                                 children: disambiguate(node.children, within: node.path))
            }
            .sorted { $0.path < $1.path }
    }

    /// A node may only be lifted to a parent that is still strictly
    /// inside its container.
    static func canLift(to parentPath: String, within container: String?) -> Bool {
        guard let container else { return true }          // top level: up to "/" is fine
        return isStrictAncestor(container, of: parentPath)
    }

    /// Every node in the forest, depth-first — for tests and lookups.
    public static func flatten(_ nodes: [FavoriteTreeNode]) -> [FavoriteTreeNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
}
