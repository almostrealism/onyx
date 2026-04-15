import XCTest
@testable import OnyxLib

// MARK: - ClaudeSessionManager Tests

final class ClaudeSessionManagerTests: XCTestCase {

    func testProcessHookEvent_sessionStart_createsSession() {
        let manager = ClaudeSessionManager()
        let event: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "test-session-1"
        ]
        let response = manager.processHookEvent(event)
        XCTAssertEqual(response["continue"] as? Bool, true)

        // Session creation happens on main queue; force a drain
        let expectation = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            XCTAssertNotNil(manager.sessions["test-session-1"])
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testProcessHookEvent_preToolUse_updatesSessionStatus() {
        let manager = ClaudeSessionManager()
        // First create a session
        _ = manager.processHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-2"
        ])

        // Then send a PreToolUse event
        let event: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "sess-2",
            "tool_name": "Bash",
            "tool_input": ["command": "ls -la"]
        ]
        let response = manager.processHookEvent(event)
        // PreToolUse returns hookSpecificOutput with permissionDecision: "defer"
        let hookOutput = response["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hookOutput?["permissionDecision"] as? String, "defer")

        let expectation = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            let session = manager.sessions["sess-2"]
            XCTAssertNotNil(session)
            XCTAssertEqual(session?.toolName, "Bash")
            if case .running(let tool) = session?.status {
                XCTAssertEqual(tool, "Bash")
            } else {
                XCTFail("Expected .running status after PreToolUse")
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testProcessHookEvent_postToolUse_resetsToIdle() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-3"
        ])
        _ = manager.processHookEvent([
            "hook_event_name": "PreToolUse",
            "session_id": "sess-3",
            "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/test.txt"]
        ])
        _ = manager.processHookEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-3"
        ])

        let expectation = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            let session = manager.sessions["sess-3"]
            XCTAssertNotNil(session)
            XCTAssertEqual(session?.status, .idle)
            XCTAssertNil(session?.toolName)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }

    func testProcessHookEvent_stop_marksSessionStopped() {
        let manager = ClaudeSessionManager()
        _ = manager.processHookEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-4"
        ])
        let response = manager.processHookEvent([
            "hook_event_name": "Stop",
            "session_id": "sess-4"
        ])
        XCTAssertEqual(response["continue"] as? Bool, true)

        let expectation = self.expectation(description: "main queue")
        DispatchQueue.main.async {
            let session = manager.sessions["sess-4"]
            XCTAssertEqual(session?.status, .stopped)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)
    }
}
