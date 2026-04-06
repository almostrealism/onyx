import XCTest
@testable import OnyxLib

// MARK: - MCP Message Handler Tests

final class MCPMessageHandlerTests: XCTestCase {

    private func makeHandler() -> (MCPMessageHandler, ArtifactManager) {
        let manager = ArtifactManager()
        let handler = MCPMessageHandler(artifactManager: manager, claudeSessions: ClaudeSessionManager())
        return (handler, manager)
    }

    // MARK: - Initialize

    func testInitialize() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(1), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)
        if case .object(let obj) = response.result {
            XCTAssertEqual(obj["protocolVersion"], .string("2024-11-05"))
            if case .object(let info) = obj["serverInfo"] {
                XCTAssertEqual(info["name"], .string("onyx"))
            } else {
                XCTFail("Missing serverInfo")
            }
        } else {
            XCTFail("Expected object result")
        }
    }

    // MARK: - Tools List

    func testToolsList() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(2), method: "tools/list")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        if case .object(let obj) = response.result,
           case .array(let tools) = obj["tools"] {
            XCTAssertEqual(tools.count, 6) // show_text, show_diagram, show_model, clear_slot, list_slots, analyze_deps
            let names = tools.compactMap { tool -> String? in
                if case .object(let t) = tool { return t["name"]?.stringValue }
                return nil
            }
            XCTAssertTrue(names.contains("show_text"))
            XCTAssertTrue(names.contains("show_diagram"))
            XCTAssertTrue(names.contains("show_model"))
            XCTAssertTrue(names.contains("clear_slot"))
            XCTAssertTrue(names.contains("list_slots"))
        } else {
            XCTFail("Expected tools array in result")
        }
    }

    // MARK: - Unknown Method

    func testUnknownMethod() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(3), method: "nonexistent/method")
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601) // method not found
    }

    // MARK: - Notifications

    func testNotificationsInitialized() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(4), method: "notifications/initialized")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result, .null)
    }

    // MARK: - handleMessage parse error

    func testHandleMessage_invalidJSON() {
        let (handler, _) = makeHandler()
        let garbage = "not json at all".data(using: .utf8)!
        let responseData = handler.handleMessage(garbage)
        XCTAssertNotNil(responseData)
        if let data = responseData,
           let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
            XCTAssertNotNil(response.error)
            XCTAssertEqual(response.error?.code, -32700) // parse error
        }
    }

    // MARK: - tools/call missing params

    func testToolsCall_missingToolName() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(5), method: "tools/call", params: [:])
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602) // invalid params
    }

    func testToolsCall_unknownTool() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(6), method: "tools/call", params: [
            "name": .string("nonexistent_tool"),
            "arguments": .object([:])
        ])
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602)
    }

    // MARK: - Response ID passthrough

    func testResponsePreservesID_int() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(42), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertEqual(response.id, .int(42))
    }

    func testResponsePreservesID_string() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .string("req-abc"), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertEqual(response.id, .string("req-abc"))
    }
}

// MARK: - AnyCodableValue Tests

final class AnyCodableValueTests: XCTestCase {

    func testStringRoundTrip() throws {
        let value = AnyCodableValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testIntRoundTrip() throws {
        let value = AnyCodableValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testBoolRoundTrip() throws {
        let value = AnyCodableValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testNullRoundTrip() throws {
        let value = AnyCodableValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testArrayRoundTrip() throws {
        let value = AnyCodableValue.array([.string("a"), .int(1), .bool(false)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.arrayValue?.count, 3)
    }

    func testObjectRoundTrip() throws {
        let value = AnyCodableValue.object(["key": .string("val"), "num": .int(5)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.objectValue?["key"], .string("val"))
    }

    func testNestedObject() throws {
        let value = AnyCodableValue.object([
            "tools": .array([
                .object(["name": .string("test"), "params": .object(["required": .bool(true)])])
            ])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testWrongAccessors() {
        let str = AnyCodableValue.string("hello")
        XCTAssertNil(str.intValue)
        XCTAssertNil(str.boolValue)
        XCTAssertNil(str.objectValue)
        XCTAssertNil(str.arrayValue)

        let num = AnyCodableValue.int(5)
        XCTAssertNil(num.stringValue)
        XCTAssertNil(num.boolValue)
    }

    func testDoubleToInt() {
        let dbl = AnyCodableValue.double(3.0)
        XCTAssertEqual(dbl.intValue, 3)
    }
}

// MARK: - JSONRPCRequest/Response Codable Tests

final class JSONRPCCodableTests: XCTestCase {

    func testRequestEncodeDecode() throws {
        let request = JSONRPCRequest(id: .int(1), method: "tools/list", params: ["cursor": .string("abc")])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.id, .int(1))
        XCTAssertEqual(decoded.method, "tools/list")
        XCTAssertEqual(decoded.params?["cursor"], .string("abc"))
    }

    func testResponseWithResult() throws {
        let response = JSONRPCResponse(id: .string("req-1"), result: .object(["status": .string("ok")]))
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertEqual(decoded.id, .string("req-1"))
        XCTAssertNotNil(decoded.result)
        XCTAssertNil(decoded.error)
    }

    func testResponseWithError() throws {
        let response = JSONRPCResponse(id: .int(5), error: .methodNotFound)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertNil(decoded.result)
        XCTAssertNotNil(decoded.error)
        XCTAssertEqual(decoded.error?.code, -32601)
    }

    func testJSONRPCError_staticValues() {
        XCTAssertEqual(JSONRPCError.parseError.code, -32700)
        XCTAssertEqual(JSONRPCError.invalidRequest.code, -32600)
        XCTAssertEqual(JSONRPCError.methodNotFound.code, -32601)
        XCTAssertEqual(JSONRPCError.invalidParams.code, -32602)
    }
}
