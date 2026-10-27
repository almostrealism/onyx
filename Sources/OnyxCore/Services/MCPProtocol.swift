//
// MCPProtocol.swift
//
// Responsibility: The JSON-RPC 2.0 messages MCP is made of, and a Codable
//                 JSON value for their params and results.
// Scope: Models, shared by every Onyx that answers the bridge.
//

import Foundation

// MARK: - JSON-RPC Types

/// JSONRPCRequest.
public struct JSONRPCRequest: Codable {
    /// Jsonrpc.
    public let jsonrpc: String
    /// Id.
    public let id: AnyCodableValue?
    /// Method.
    public let method: String
    /// Params.
    public let params: [String: AnyCodableValue]?

    /// Create a new instance.
    public init(jsonrpc: String = "2.0", id: AnyCodableValue? = nil, method: String, params: [String: AnyCodableValue]? = nil) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSONRPCResponse.
public struct JSONRPCResponse: Codable {
    /// Jsonrpc.
    public let jsonrpc: String
    /// Id.
    public let id: AnyCodableValue?
    /// Result.
    public let result: AnyCodableValue?
    /// Error.
    public let error: JSONRPCError?

    /// Create a new instance.
    public init(id: AnyCodableValue?, result: AnyCodableValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    /// Create a new instance.
    public init(id: AnyCodableValue?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// JSONRPCError.
public struct JSONRPCError: Codable {
    /// Code.
    public let code: Int
    /// Message.
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    /// Parse error.
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    /// Invalid request.
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    /// Method not found.
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    /// Invalid params.
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
}

/// Type-erased Codable value for JSON-RPC flexibility
public enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    /// Create a new instance.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) } else if let v = try? container.decode(Int.self) { self = .int(v) } else if let v = try? container.decode(Double.self) { self = .double(v) } else if let v = try? container.decode(String.self) { self = .string(v) } else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) } else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) } else if container.decodeNil() { self = .null } else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type") }
    }

    /// Encode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// String value.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Double value. Accepts an int too — JSON makes no distinction and a
    /// timestamp arrives as either.
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        if case .int(let v) = self { return Double(v) }
        return nil
    }

    /// Int value.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        if case .double(let v) = self { return Int(v) }
        return nil
    }

    /// Bool value.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Object value.
    public var objectValue: [String: AnyCodableValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// Array value.
    public var arrayValue: [AnyCodableValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
}

// MARK: - MCP Message Handler

/// MCPMessageHandler.
