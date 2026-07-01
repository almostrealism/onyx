//
// LSPModels.swift
//
// Responsibility: Pure data types for the subset of the Language Server
//                 Protocol (LSP) that the code-navigation feature uses to talk
//                 to the Eclipse JDT language server (jdtls). Wire-level types
//                 only — no I/O, no ObservableObject, no dependencies.
// Scope: Model. Depends on nothing.
//
// LSP reference: positions are ZERO-BASED, and `character` is a UTF-16 code
// unit offset (not a Swift Character or byte offset). See the jdtls spike
// (spike/README.md) for the requests these types support.
//

import Foundation

/// A zero-based position in a text document. `character` is a UTF-16 offset.
public struct LSPPosition: Codable, Hashable {
    public var line: Int
    public var character: Int
    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A half-open range [start, end) in a text document.
public struct LSPRange: Codable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition
    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// A location: a range within a document identified by URI. jdtls returns
/// these for `textDocument/implementation`, `.../references`, `.../definition`.
public struct LSPLocation: Codable, Hashable {
    public var uri: String
    public var range: LSPRange
    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// LSP SymbolKind — the ones we actually surface. Raw values follow the spec.
public enum LSPSymbolKind: Int, Codable {
    case file = 1, module = 2, namespace = 3, package = 4, `class` = 5
    case method = 6, property = 7, field = 8, constructor = 9, `enum` = 10
    case interface = 11, function = 12, variable = 13, constant = 14
    case string = 15, number = 16, boolean = 17, array = 18, object = 19
    case key = 20, null = 21, enumMember = 22, `struct` = 23, event = 24
    case `operator` = 25, typeParameter = 26

    /// A short label for UI ("class", "interface", "method", …).
    public var label: String {
        switch self {
        case .class: return "class"
        case .interface: return "interface"
        case .enum: return "enum"
        case .struct: return "record"
        case .method: return "method"
        case .constructor: return "constructor"
        case .field: return "field"
        case .function: return "function"
        default: return ""
        }
    }
}

/// An item in a type hierarchy — returned by `textDocument/prepareTypeHierarchy`
/// and the input to `typeHierarchy/{sub,super}types`.
///
/// Round-trips verbatim: we hand jdtls back the exact item it gave us (it may
/// carry an opaque `data` field), so this preserves unknown keys via `extra`.
public struct TypeHierarchyItem: Codable, Hashable {
    public var name: String
    public var kind: Int
    public var uri: String
    public var range: LSPRange
    public var selectionRange: LSPRange
    public var detail: String?
    /// Opaque server-defined payload; must be echoed back unchanged.
    public var data: LSPJSONValue?

    public var symbolKind: LSPSymbolKind? { LSPSymbolKind(rawValue: kind) }
    public var location: LSPLocation { LSPLocation(uri: uri, range: selectionRange) }
}

/// A minimal JSON value, used to carry LSP's opaque `data` payloads through
/// our typed models without losing or reinterpreting them.
public enum LSPJSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LSPJSONValue])
    case object([String: LSPJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([LSPJSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: LSPJSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Convert to a Foundation object suitable for JSONSerialization.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundationValue)
        case .object(let v): return v.mapValues(\.foundationValue)
        }
    }

    /// Build from a Foundation object (as produced by JSONSerialization).
    public init(foundation: Any) {
        switch foundation {
        case is NSNull: self = .null
        case let n as NSNumber:
            // Distinguish bool from numeric (NSNumber bridges both).
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.stringValue.contains(".") { self = .double(n.doubleValue) }
            else { self = .int(n.intValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(LSPJSONValue.init(foundation:)))
        case let o as [String: Any]: self = .object(o.mapValues(LSPJSONValue.init(foundation:)))
        default: self = .null
        }
    }
}
