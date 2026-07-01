//
// CodeNavModels.swift
//
// Responsibility: UI-facing value types for code navigation results. These are
//                 what the file browser renders — decoupled from the LSP wire
//                 types in LSPModels.swift so the Views never touch protocol
//                 details.
// Scope: Model. Depends only on Foundation.
//

import Foundation

/// A navigation query the user can run on a symbol.
public enum NavKind: String, CaseIterable, Hashable {
    case subtypes           // subclasses / implementing types
    case supertypes         // superclasses / implemented interfaces
    case implementation     // implementors of an interface, overrides of a method
    case references         // all usages
    case definition         // go to definition

    /// Menu / button label.
    public var label: String {
        switch self {
        case .subtypes: return "Subtypes"
        case .supertypes: return "Supertypes"
        case .implementation: return "Implementors"
        case .references: return "References"
        case .definition: return "Definition"
        }
    }

    /// SF Symbol for the action.
    public var systemImage: String {
        switch self {
        case .subtypes: return "arrow.down.to.line"
        case .supertypes: return "arrow.up.to.line"
        case .implementation: return "square.stack.3d.up"
        case .references: return "text.magnifyingglass"
        case .definition: return "arrow.right.to.line"
        }
    }
}

/// A single navigation hit: a location in a file, with light context.
public struct NavResult: Identifiable, Hashable {
    public let id = UUID()
    /// Absolute remote path to the file.
    public var path: String
    /// One-based line number (for display and jump-to-line).
    public var line: Int
    /// Zero-based UTF-16 character offset of the match on that line.
    public var character: Int
    /// Symbol name if the server provided one (type hierarchy does; plain
    /// locations don't).
    public var name: String?
    /// Symbol kind label ("class", "interface", …) when known.
    public var kindLabel: String?

    public init(path: String, line: Int, character: Int, name: String? = nil, kindLabel: String? = nil) {
        self.path = path
        self.line = line
        self.character = character
        self.name = name
        self.kindLabel = kindLabel
    }

    /// Just the file name for display.
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Navigation results grouped by file — the shape the results panel renders.
public struct NavResultGroup: Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var results: [NavResult]

    public var fileName: String { (path as NSString).lastPathComponent }

    public init(path: String, results: [NavResult]) {
        self.path = path
        self.results = results
    }

    /// Group a flat list of results by file path, sorted by file name then line.
    public static func group(_ results: [NavResult]) -> [NavResultGroup] {
        let byPath = Dictionary(grouping: results, by: \.path)
        return byPath.map { path, hits in
            NavResultGroup(path: path, results: hits.sorted { $0.line < $1.line })
        }
        .sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }
}

/// The state of a navigation query, for the UI to render.
public enum CodeNavState {
    case idle
    case indexing(root: String)     // jdtls importing the workspace
    case running(NavKind)
    case results(kind: NavKind, symbol: String?, groups: [NavResultGroup])
    case empty(kind: NavKind)       // query ran, no hits
    case unavailable(reason: String)  // no project, jdtls missing, error
}
