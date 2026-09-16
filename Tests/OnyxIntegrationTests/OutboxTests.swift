import XCTest
import Foundation

/// The outbox, exercised through the real binary.
///
/// "Nobody is around, undeliverable" was the end of the story, and it
/// shouldn't be: an agent that finishes at 2am and finds the desktop
/// unreachable has still finished, and the person still wants to know. The
/// alert isn't less true for arriving late — dropping it puts the cost of
/// an infrastructure problem onto the one message worth sending.
///
/// Driven through the binary rather than the type because the behavior
/// that matters is what the AGENT is told and what survives the process
/// exiting.
final class OutboxTests: XCTestCase {

    private func sandbox() throws -> (env: [String: String], home: URL) {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        env["HOME"] = home.path
        env["ONYX_MCP_FORWARD_PORT"] = "0"       // no backend anywhere
        env.removeValue(forKey: "ONYX_MCP_PORT")
        return (env, home)
    }

    private var notifyCall: String {
        #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"notify","arguments":{"title":"Migration finished","urgent":true}}}
        """# + "\n"
    }

    private func outboxFile(_ home: URL) -> URL {
        home.appendingPathComponent(".onyx/outbox.jsonl")
    }

    func testAnUndeliverableAlertIsQueuedRatherThanLost() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let (env, home) = try sandbox()

        let result = IntegrationTestHelpers.runProcess(
            binary, stdin: notifyCall, environment: env, timeout: 15.0)

        XCTAssertFalse(result.timedOut)
        let queued = try String(contentsOf: outboxFile(home), encoding: .utf8)
        XCTAssertTrue(queued.contains("Migration finished"),
                      "the alert should be on disk, not gone: \(queued)")
    }

    /// What the agent is told matters as much as what we keep. An error
    /// invites a retry, and a retry means the person gets it twice.
    func testTheAgentIsToldItWasQueuedAndNotToResend() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let (env, _) = try sandbox()

        let result = IntegrationTestHelpers.runProcess(
            binary, stdin: notifyCall, environment: env, timeout: 15.0)

        XCTAssertTrue(result.stdout.contains("QUEUED"), result.stdout)
        XCTAssertTrue(result.stdout.lowercased().contains("resend"), result.stdout)
        XCTAssertTrue(result.stdout.contains("\"result\""),
                      "a queued alert is an outcome, not a failure: \(result.stdout)")
        XCTAssertFalse(result.stdout.contains("\"error\""), result.stdout)
    }

    /// Publishing a page to a desktop nobody can reach is pointless to
    /// replay — it will be stale, and the agent will publish a fresh one.
    func testOnlyAlertsAreQueued() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let (env, home) = try sandbox()
        let showCall = #"""
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_html","arguments":{"slot":1,"title":"x","content":"<p>hi</p>"}}}
        """# + "\n"

        let result = IntegrationTestHelpers.runProcess(
            binary, stdin: showCall, environment: env, timeout: 15.0)

        XCTAssertTrue(result.stdout.contains("\"error\""),
                      "a page that can't be shown is a plain failure: \(result.stdout)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxFile(home).path),
                       "nothing should have been queued")
    }

    /// The queue has to outlive the process — the bridge is short-lived
    /// and gets killed whenever a Claude session ends.
    func testTheQueueSurvivesTheProcessAndAccumulates() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let (env, home) = try sandbox()

        for i in 1...2 {
            let call = #"{"jsonrpc":"2.0","id":\#(i),"method":"tools/call","params":"# +
                #"{"name":"notify","arguments":{"title":"alert \#(i)"}}}"# + "\n"
            _ = IntegrationTestHelpers.runProcess(binary, stdin: call,
                                                  environment: env, timeout: 15.0)
        }

        let queued = try String(contentsOf: outboxFile(home), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(queued.count, 2, "both sessions' alerts should be waiting")
        XCTAssertTrue(queued[0].contains("alert 1") && queued[1].contains("alert 2"),
                      "and in the order they were sent")
    }

    /// A replayed alert carries when it was SENT. Otherwise it claims to
    /// have happened whenever the network came back, which is the one
    /// detail that would make it misleading.
    func testAQueuedAlertRemembersWhenItWasSent() throws {
        let binary = try IntegrationTestHelpers.requireOnyxMCPBinary()
        let (env, home) = try sandbox()
        _ = IntegrationTestHelpers.runProcess(binary, stdin: notifyCall,
                                              environment: env, timeout: 15.0)

        let line = try String(contentsOf: outboxFile(home), encoding: .utf8)
            .components(separatedBy: "\n").first { !$0.isEmpty } ?? ""
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let at = try XCTUnwrap(object["at"] as? Double)
        XCTAssertEqual(at, Date().timeIntervalSince1970, accuracy: 120,
                       "the queue records the moment the agent sent it")
    }
}
