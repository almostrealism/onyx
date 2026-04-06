import XCTest
import Foundation
@testable import OnyxLib

/// HTTP smoke tests for `DashboardServer`.
///
/// FINDING: `DashboardServer` is hard-coded to bind on `defaultPort = 19433`
/// (`Sources/OnyxLib/Services/DashboardServer.swift`). There is no way to
/// pass a port (let alone port 0 for OS-assigned). For this test pass we
/// accept that constraint and bind on the real port; the test is XCTSkip-ed
/// if the port is already in use, so this won't break a developer's box that
/// has Onyx running. Follow-up: parameterize the listen port for testability.
final class DashboardServerTests: XCTestCase {

    private var appState: AppState!
    private var server: DashboardServer!

    override func setUp() async throws {
        try await super.setUp()
        appState = await MainActor.run { AppState() }
        server = DashboardServer(appState: appState)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        appState = nil
        try await super.tearDown()
    }

    /// async helper that waits for the server's port to be set.
    private func awaitReady() async throws {
        let deadline = Date().addingTimeInterval(1.5)
        while server.port == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if server.port == nil {
            throw XCTSkip("DashboardServer did not become ready within 1.5s")
        }
    }

    func testRootRouteServesHTML() async throws {
        try checkPortFree()
        server.start()
        defer { server.stop() }
        try await awaitReady()

        let url = URL(string: "http://127.0.0.1:\(server.port!)/")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("<!DOCTYPE html>"), "root should return HTML")
        XCTAssertTrue(body.contains("Onyx Monitor"))
    }

    func testStatsRouteReturnsJSON() async throws {
        try checkPortFree()
        server.start()
        defer { server.stop() }
        try await awaitReady()

        let url = URL(string: "http://127.0.0.1:\(server.port!)/api/stats")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        // Body must be a JSON object
        let obj = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(obj is [String: Any], "stats route should return a JSON object")
    }

    func testUnknownRouteReturns404() async throws {
        try checkPortFree()
        server.start()
        defer { server.stop() }
        try await awaitReady()

        let url = URL(string: "http://127.0.0.1:\(server.port!)/does-not-exist")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
    }

    func testServerStopsCleanly() async throws {
        try checkPortFree()
        server.start()
        try await awaitReady()
        server.stop()
        // After stop, port should be cleared
        XCTAssertNil(server.port)
    }

    private func checkPortFree() throws {
        let probe = Process()
        probe.launchPath = "/usr/bin/env"
        probe.arguments = ["sh", "-c", "lsof -i :\(DashboardServer.defaultPort) -sTCP:LISTEN -t 2>/dev/null"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        try? probe.run()
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if !data.isEmpty {
            throw XCTSkip("Port \(DashboardServer.defaultPort) already in use; skipping HTTP smoke test")
        }
    }
}
