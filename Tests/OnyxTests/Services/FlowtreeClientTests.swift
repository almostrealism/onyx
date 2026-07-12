import XCTest
@testable import OnyxLib

final class FlowtreeClientTests: XCTestCase {

    // MARK: - request building

    func test_makeRequest_composesURL_strippingTrailingSlashes() {
        let cfg = FlowtreeConfig(baseURL: "https://ft.example.com//")
        let req = FlowtreeClient.makeRequest(config: cfg, path: "/api/workstreams", method: "GET")
        XCTAssertEqual(req?.url?.absoluteString, "https://ft.example.com/api/workstreams")
        XCTAssertEqual(req?.httpMethod, "GET")
    }

    func test_makeRequest_emptyBaseURL_returnsNil() {
        XCTAssertNil(FlowtreeClient.makeRequest(config: FlowtreeConfig(baseURL: "  "),
                                                path: "/api/health", method: "GET"))
    }

    func test_makeRequest_attachesCFAccessHeaders_whenBothSet() {
        let cfg = FlowtreeConfig(baseURL: "https://ft.example.com", clientId: "cid", clientSecret: "secret")
        let req = FlowtreeClient.makeRequest(config: cfg, path: "/api/workstreams", method: "GET")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "CF-Access-Client-Id"), "cid")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "secret")
    }

    func test_makeRequest_omitsCFAccessHeaders_whenMissing() {
        // Local instance: no credentials → no headers.
        let cfg = FlowtreeConfig(baseURL: "http://localhost:7780", clientId: "", clientSecret: "")
        let req = FlowtreeClient.makeRequest(config: cfg, path: "/api/workstreams", method: "GET")
        XCTAssertNil(req?.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertNil(req?.value(forHTTPHeaderField: "CF-Access-Client-Secret"))
    }

    func test_makeRequest_omitsCFAccessHeaders_whenOnlyOneSet() {
        let cfg = FlowtreeConfig(baseURL: "https://ft.example.com", clientId: "cid", clientSecret: "")
        let req = FlowtreeClient.makeRequest(config: cfg, path: "/api/workstreams", method: "GET")
        XCTAssertNil(req?.value(forHTTPHeaderField: "CF-Access-Client-Id"))
    }

    func test_makeRequest_postSetsJSONBodyAndContentType() throws {
        let cfg = FlowtreeConfig(baseURL: "https://ft.example.com")
        let req = FlowtreeClient.makeRequest(config: cfg, path: "/api/submit", method: "POST",
                                             jsonBody: ["workstreamId": "ws-1", "prompt": "do the thing"])
        XCTAssertEqual(req?.httpMethod, "POST")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(req?.httpBody)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(obj?["workstreamId"] as? String, "ws-1")
        XCTAssertEqual(obj?["prompt"] as? String, "do the thing")
    }

    // MARK: - decode

    func test_decodeWorkstreams_realShape() throws {
        let json = """
        [
          {"workstreamId":"ws-foo","channelName":"w-feature-foo","repoUrl":"https://github.com/org/repo",
           "defaultBranch":"feature/foo","githubOrg":"org"},
          {"workstreamId":"ws-bar","archived":true}
        ]
        """
        let ws = try JSONDecoder().decode([FlowtreeWorkstream].self, from: Data(json.utf8))
        XCTAssertEqual(ws.count, 2)
        XCTAssertEqual(ws[0].displayName, "w-feature-foo")
        XCTAssertEqual(ws[0].subtitle, "repo · feature/foo")
        XCTAssertFalse(ws[0].isArchived)
        XCTAssertEqual(ws[1].displayName, "ws-bar", "no channel → falls back to id")
        XCTAssertTrue(ws[1].isArchived)
    }

    func test_decodeSubmitResult_successAndError() throws {
        let ok = try JSONDecoder().decode(FlowtreeSubmitResult.self,
            from: Data(#"{"ok":true,"jobId":"task-123"}"#.utf8))
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.jobId, "task-123")

        let fail = try JSONDecoder().decode(FlowtreeSubmitResult.self,
            from: Data(#"{"ok":false,"error":"Unknown workstream"}"#.utf8))
        XCTAssertFalse(fail.ok)
        XCTAssertEqual(fail.error, "Unknown workstream")
    }

    // MARK: - config store

    func test_configStore_persistsAndReportsConfigured() {
        let store = FlowtreeConfigStore.shared
        store.resetForTesting()
        XCTAssertFalse(store.isConfigured)
        store.controllerURL = "https://ft.example.com"
        store.clientId = "cid"
        store.clientSecret = "sec"
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.config.hasAccessToken)
        XCTAssertEqual(store.config.baseURL, "https://ft.example.com")
        store.resetForTesting()
    }
}
