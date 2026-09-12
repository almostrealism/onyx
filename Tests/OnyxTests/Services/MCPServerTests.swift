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
            XCTAssertEqual(tools.count, 9) // show_*, clear_slot, list_slots, analyze_deps, notify, show_html, onyx_guide
            let names = tools.compactMap { tool -> String? in
                if case .object(let t) = tool { return t["name"]?.stringValue }
                return nil
            }
            XCTAssertTrue(names.contains("notify"))
            XCTAssertTrue(names.contains("show_html"))
            XCTAssertTrue(names.contains("onyx_guide"))
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

    /// Only reachable when a client puts an id on a notification, which is
    /// malformed. The real path — no id at all — is asserted in
    /// MCPNotificationTests, where the answer is NO REPLY.
    func testNotificationsInitializedWithAnIdIsHumoured() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(4), method: "notifications/initialized")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result, .object([:]),
                       "a null result is not a valid JSON-RPC result object")
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

/// Routing an alert to a session. An alert on the WRONG session is worse
/// than an unattached one — it lights a light next to work that isn't
/// waiting on anything — so ambiguity has to resolve to "no session",
/// never to a guess.
final class AlertRoutingTests: XCTestCase {

    private let candidates = [
        (key: "host:me@build-01:trainer", user: "me", host: "build-01", session: "trainer"),
        (key: "host:me@build-01:api", user: "me", host: "build-01", session: "api"),
        (key: "host:you@build-02:api", user: "you", host: "build-02", session: "api"),
    ]

    private func resolve(_ user: String?, _ host: String?, _ session: String?) -> String? {
        AlertRouting.resolve(user: user, host: host, session: session, candidates: candidates)
    }

    func testAllThreeDetailsMatchExactly() {
        XCTAssertEqual(resolve("me", "build-01", "trainer"), "host:me@build-01:trainer")
    }

    /// The common case worth being generous about: one unique session
    /// name is enough, so an agent doesn't have to run three commands to
    /// say where it is.
    func testAUniqueSessionNameAloneIsEnough() {
        XCTAssertEqual(resolve(nil, nil, "trainer"), "host:me@build-01:trainer")
    }

    /// "api" exists twice. Guessing would light the wrong session.
    func testAnAmbiguousNameResolvesToNothing() {
        XCTAssertNil(resolve(nil, nil, "api"))
    }

    func testAmbiguityIsResolvedByAnyAdditionalDetail() {
        XCTAssertEqual(resolve(nil, "build-02", "api"), "host:you@build-02:api")
        XCTAssertEqual(resolve("me", nil, "api"), "host:me@build-01:api")
    }

    /// People and machines disagree about whether a host is short or
    /// fully qualified; both directions should match.
    func testHostNamesMatchAcrossTheDomainSuffix() {
        let fq = [(key: "k", user: "me", host: "build-01.example.com", session: "api")]
        XCTAssertEqual(AlertRouting.resolve(user: nil, host: "build-01", session: nil,
                                            candidates: fq), "k")
        let short = [(key: "k", user: "me", host: "build-01", session: "api")]
        XCTAssertEqual(AlertRouting.resolve(user: nil, host: "build-01.example.com",
                                            session: nil, candidates: short), "k")
    }

    /// …but not loosely. "build" naming "buildsomething" would attach
    /// alerts to a machine the agent never mentioned.
    func testAPrefixIsNotEnoughWithoutADotBoundary() {
        let other = [(key: "k", user: "me", host: "buildsomething", session: "api")]
        XCTAssertNil(AlertRouting.resolve(user: nil, host: "build", session: nil,
                                          candidates: other))
    }

    func testNoDetailsMeansNoSession() {
        XCTAssertNil(resolve(nil, nil, nil))
        XCTAssertNil(resolve("", "  ", nil), "blank strings are not a target")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(resolve("ME", "BUILD-01", "Trainer"), "host:me@build-01:trainer")
    }

    func testANameThatMatchesNothingResolvesToNothing() {
        XCTAssertNil(resolve(nil, nil, "no-such-session"))
    }

    // MARK: - The su case

    /// You sign in as one account and run the agent as another. `whoami`
    /// inside the agent then reports a user Onyx never connected as — but
    /// the host and the tmux session name are still right, and together
    /// they name exactly one session. Trust that over the user.
    func testAWrongUserIsIgnoredWhenHostAndSessionSingleOutOneSession() {
        let m = AlertRouting.match(user: "root", host: "build-01", session: "trainer",
                                   candidates: candidates)
        XCTAssertEqual(m.key, "host:me@build-01:trainer")
        XCTAssertTrue(m.ignoredUser, "the caller should be told its user didn't match")
    }

    /// A right answer must not be reported as a relaxed one, or the reply
    /// tells every correct agent its user is wrong.
    func testAnExactMatchDoesNotClaimToHaveIgnoredTheUser() {
        let m = AlertRouting.match(user: "me", host: "build-01", session: "trainer",
                                   candidates: candidates)
        XCTAssertEqual(m.key, "host:me@build-01:trainer")
        XCTAssertFalse(m.ignoredUser)
    }

    /// Relaxing must not turn an ambiguous aim into a match. "api" on no
    /// particular host is two sessions with or without the user.
    func testRelaxingTheUserDoesNotResolveAnAmbiguousSessionName() {
        XCTAssertNil(resolve("nobody", nil, "api"))
    }

    /// The session name alone is enough, even with a wrong user attached.
    func testAWrongUserIsIgnoredWhenTheSessionNameIsUniqueOnItsOwn() {
        XCTAssertEqual(resolve("root", nil, "trainer"), "host:me@build-01:trainer")
    }

    /// One session on a host, named wrongly by user: the host alone
    /// narrows it, so take it.
    func testAWrongUserIsIgnoredWhenTheHostHasOnlyOneSession() {
        XCTAssertEqual(resolve("root", "build-02", nil), "host:you@build-02:api")
    }

    /// A user is the ONE thing that can't stand alone after relaxation:
    /// dropping it leaves no aim at all, and "the only session there is"
    /// is not a match. Onyx would attach the alert to whatever happens to
    /// be running.
    func testAUserAloneNeverResolvesByRelaxation() {
        let one = [(key: "k", user: "me", host: "build-01", session: "trainer")]
        XCTAssertNil(AlertRouting.resolve(user: "someone-else", host: nil, session: nil,
                                          candidates: one))
    }

    /// And a correct user alone still works when it's unambiguous — the
    /// relaxation is additive, not a replacement.
    func testACorrectUserAloneStillResolves() {
        XCTAssertEqual(resolve("you", nil, nil), "host:you@build-02:api")
    }
}

/// The store behind the indicator.
final class AlertStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AlertStore.shared.resetForTesting()
    }

    private func record(_ title: String, key: String?, urgent: Bool = false) {
        AlertStore.shared.record(SessionAlert(title: title, urgent: urgent, sessionKey: key))
    }

    func testAnAlertLightsItsOwnSessionAndNoOther() {
        record("build done", key: "host:me@a:one")
        XCTAssertTrue(AlertStore.shared.hasUnseen(for: "host:me@a:one"))
        XCTAssertFalse(AlertStore.shared.hasUnseen(for: "host:me@a:two"))
    }

    /// "Seen" means "I've looked", not "throw it away" — the message you
    /// were away for is the one you most want to re-read.
    func testMarkingSeenClearsTheLightButKeepsTheHistory() {
        record("first", key: "k")
        record("second", key: "k")
        AlertStore.shared.markSeen(for: "k")

        XCTAssertFalse(AlertStore.shared.hasUnseen(for: "k"))
        XCTAssertEqual(AlertStore.shared.alerts(for: "k").count, 2)
    }

    func testANewAlertLightsItAgain() {
        record("first", key: "k")
        AlertStore.shared.markSeen(for: "k")
        record("second", key: "k")
        XCTAssertEqual(AlertStore.shared.unseenCount(for: "k"), 1)
    }

    func testNewestFirst() {
        record("older", key: "k")
        record("newer", key: "k")
        XCTAssertEqual(AlertStore.shared.alerts(for: "k").first?.title, "newer")
    }

    /// An agent in a loop must not be able to grow this without bound.
    func testHistoryIsCappedPerSession() {
        for i in 0..<(AlertStore.maxPerSession + 25) { record("m\(i)", key: "k") }
        XCTAssertEqual(AlertStore.shared.alerts(for: "k").count, AlertStore.maxPerSession)
        XCTAssertEqual(AlertStore.shared.alerts(for: "k").first?.title,
                       "m\(AlertStore.maxPerSession + 24)", "the newest are the ones kept")
    }

    func testAlertsWithNoSessionGoSomewhereReachable() {
        record("unattached", key: nil)
        XCTAssertEqual(AlertStore.shared.alerts(for: nil).count, 1)
        XCTAssertTrue(AlertStore.shared.hasUnseen(for: nil))
    }

    /// A killed session's history goes with it — otherwise it's a light
    /// nobody can reach and a list nobody can open.
    func testForgettingASessionDropsItsAlerts() {
        record("gone", key: "k")
        AlertStore.shared.forget(key: "k")
        XCTAssertTrue(AlertStore.shared.alerts(for: "k").isEmpty)
    }
}

/// Notifications. A JSON-RPC message with no id must get NO reply.
///
/// This one shipped broken for months and was invisible from inside the
/// app: the server answered `notifications/cancelled` — sent by the client
/// every time the user interrupts — with `{"result":null}`, which is not a
/// valid response object. Claude Code validates what it receives and drops
/// the connection, reporting "Failed to reconnect to onyx" against whatever
/// ran next rather than against the interrupt that caused it.
final class MCPNotificationTests: XCTestCase {

    private func handler() -> MCPMessageHandler {
        MCPMessageHandler(artifactManager: ArtifactManager(),
                          claudeSessions: ClaudeSessionManager())
    }

    private func send(_ json: String) -> Data? {
        handler().handleMessage(Data(json.utf8))
    }

    func testTheInitializedNotificationIsNotAnswered() {
        XCTAssertNil(send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    /// The one that actually breaks sessions: sent on every interrupt.
    func testTheCancelledNotificationIsNotAnswered() {
        XCTAssertNil(send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
    }

    /// An unknown notification must not get methodNotFound either — an
    /// error response with no id is just as invalid as a result with none.
    func testAnUnknownNotificationIsNotAnswered() {
        XCTAssertNil(send(#"{"jsonrpc":"2.0","method":"notifications/somethingNew"}"#))
    }

    func testAnExplicitNullIdIsAlsoANotification() {
        XCTAssertNil(send(#"{"jsonrpc":"2.0","id":null,"method":"notifications/initialized"}"#))
    }

    // MARK: - …and real requests still get answered

    func testARequestWithAnIdIsStillAnswered() {
        guard let data = send(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#) else {
            return XCTFail("a request with an id must be answered")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(json?["result"])
        XCTAssertNotNil(json?["id"])
    }

    /// A parse error is the one case where a null id is correct: there was
    /// no readable id to echo back.
    func testAnUnparseableMessageStillGetsAParseError() {
        guard let data = send("{not json") else {
            return XCTFail("a malformed message must still be reported")
        }
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("-32700") == true)
    }

    /// Unknown METHODS with an id are a different thing entirely and must
    /// still be told off.
    func testAnUnknownMethodWithAnIdStillGetsMethodNotFound() {
        guard let data = send(#"{"jsonrpc":"2.0","id":3,"method":"no/such"}"#) else {
            return XCTFail("a request with an id must be answered")
        }
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("-32601") == true)
    }
}
