import XCTest
@testable import OnyxLib

/// The guide is the only thing that tells an agent how the tools fit
/// together, so the failure mode is quiet: it goes stale, keeps being
/// returned, and sends agents to a tool that changed or no longer
/// exists. These pin it to reality rather than to its own prose.
final class OnyxGuideTests: XCTestCase {

    private func handler() -> MCPMessageHandler {
        MCPMessageHandler(artifactManager: ArtifactManager(),
                          claudeSessions: ClaudeSessionManager())
    }

    private var advertisedToolNames: [String] {
        let response = handler().dispatch(JSONRPCRequest(id: .int(1), method: "tools/list"))
        guard case .object(let obj) = response.result,
              case .array(let tools) = obj["tools"] else { return [] }
        return tools.compactMap { tool in
            if case .object(let t) = tool { return t["name"]?.stringValue }
            return nil
        }
    }

    /// THE test. Every tool an agent can see has to be mentioned
    /// somewhere in the guide, or the guide is teaching an incomplete
    /// API — which is worse than no guide, because it reads as complete.
    func testEveryAdvertisedToolAppearsInTheGuide() {
        let allText = OnyxGuide.topics.map(\.body).joined(separator: "\n")
        for name in advertisedToolNames where name != "onyx_guide" {
            XCTAssertTrue(allText.contains(name),
                          "\(name) is offered to agents but the guide never mentions it")
        }
    }

    /// And the reverse: the guide must not advertise a tool that isn't
    /// there. An agent following it would call something that doesn't
    /// exist and have to recover from an error we could have prevented.
    func testTheGuideDoesNotInventTools() {
        let advertised = Set(advertisedToolNames)
        let referenced = ["show_html", "show_text", "show_diagram", "show_model", "notify"]
        for name in referenced {
            XCTAssertTrue(advertised.contains(name),
                          "the guide tells agents to call \(name), which is not offered")
        }
    }

    // MARK: - Shape

    func testAnUnknownTopicLandsOnTheOverviewRatherThanFailing() {
        let response = OnyxGuide.response(for: "nonsense")
        XCTAssertTrue(response.contains("# overview"))
        XCTAssertTrue(response.contains("artifacts"), "and lists what it could have asked for")
    }

    func testNoTopicMeansTheOverview() {
        XCTAssertEqual(OnyxGuide.topic(nil).id, "overview")
        XCTAssertEqual(OnyxGuide.topic("").id, "overview")
        XCTAssertEqual(OnyxGuide.topic("  ARTIFACTS ").id, "artifacts")
    }

    func testEveryTopicEndsUpReachable() {
        for id in OnyxGuide.index {
            XCTAssertEqual(OnyxGuide.topic(id).id, id)
            XCTAssertFalse(OnyxGuide.topic(id).body.isEmpty)
        }
        // Every response carries the index, so one call is enough to
        // discover the rest.
        for id in OnyxGuide.index {
            let text = OnyxGuide.response(for: id)
            for other in OnyxGuide.index {
                XCTAssertTrue(text.contains(other), "\(id) should still list \(other)")
            }
        }
    }

    // MARK: - The advice that keeps being needed

    /// The single most expensive mistake an agent can make here: a remote
    /// agent passing a file path, which Onyx resolves on its own machine
    /// and either misses or matches the WRONG file.
    func testTheRemoteFilePathTrapIsCalledOut() {
        let artifacts = OnyxGuide.topic("artifacts").body
        XCTAssertTrue(artifacts.contains("content"))
        XCTAssertTrue(artifacts.lowercased().contains("remote"))
    }

    /// Publishing after notifying means the user arrives at an empty slot.
    func testRecipesSayToPublishBeforeNotifying() {
        XCTAssertTrue(OnyxGuide.topic("recipes").body.contains("BEFORE"))
    }

    /// The flags are described by intent, with the macOS behaviour named
    /// rather than assumed — an agent should know what `urgent` costs the
    /// user before spending it.
    func testAlertsExplainWhatTheFlagsActuallyDo() {
        let alerts = OnyxGuide.topic("alerts").body
        XCTAssertTrue(alerts.contains("urgent") && alerts.contains("external"))
        XCTAssertTrue(alerts.contains("dock"), "say what urgent does on a Mac")
        XCTAssertTrue(alerts.contains("Notification Center"))
    }

    /// The user's own test case is "write me a skill that reports and
    /// shows it", so the skills topic has to cover the whole shape.
    func testTheSkillsTopicCoversTheWholeLoop() {
        let skills = OnyxGuide.topic("skills").body
        XCTAssertTrue(skills.contains("show_html"))
        XCTAssertTrue(skills.contains("notify"))
        XCTAssertTrue(skills.contains("slot"))
    }

    func testSessionsTopicGivesTheCommandsToFindTheValues() {
        let sessions = OnyxGuide.topic("sessions").body
        XCTAssertTrue(sessions.contains("whoami"))
        XCTAssertTrue(sessions.contains("hostname"))
        XCTAssertTrue(sessions.contains("tmux display-message"))
    }
}
