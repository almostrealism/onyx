import Foundation
import Combine

// MARK: - Claude Code Session Tracking

/// Represents an active Claude Code session detected via hooks
public struct ClaudeActivity: Identifiable {
    public let id: String          // session_id
    public var toolName: String?   // current tool being used
    public var toolInput: String?  // summary of tool input
    public var lastSeen: Date
    public var status: ClaudeStatus

    public enum ClaudeStatus: Equatable {
        case idle
        case running(tool: String)
        case waitingPermission
        case stopped
    }
}

/// A pending permission request from Claude Code
public struct PermissionRequest: Identifiable {
    public let id: String          // unique request ID
    public let sessionId: String
    public let toolName: String
    public let toolInput: [String: Any]
    public let timestamp: Date
    public var resolved: Bool = false

    /// Human-readable summary of what's being requested
    public var summary: String {
        if toolName == "Bash" || toolName == "bash" {
            if let cmd = toolInput["command"] as? String {
                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 80 ? String(trimmed.prefix(80)) + "..." : trimmed
            }
        }
        if toolName == "Edit" || toolName == "Write" {
            if let path = toolInput["file_path"] as? String {
                return (path as NSString).lastPathComponent
            }
        }
        return toolName
    }
}

/// Tracks Claude Code sessions across all terminals via hook events
public class ClaudeSessionManager: ObservableObject {
    @Published public var sessions: [String: ClaudeActivity] = [:]
    @Published public var pendingPermissions: [PermissionRequest] = []
    @Published public var recentTools: [(date: Date, session: String, tool: String)] = []

    private let lock = NSLock()
    /// Completion handlers waiting for permission responses, keyed by request ID
    private var permissionCallbacks: [String: (String) -> Void] = [:]

    public init() {}

    // MARK: - Hook Event Processing

    /// Process a hook event from Claude Code. Returns a JSON response string.
    /// For permission requests, this blocks until the user responds via the UI.
    public func processHookEvent(_ event: [String: Any]) -> [String: Any] {
        let eventName = event["hook_event_name"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? "unknown"

        switch eventName {
        case "PreToolUse":
            return handlePreToolUse(event, sessionId: sessionId)
        case "PostToolUse":
            return handlePostToolUse(event, sessionId: sessionId)
        case "PermissionRequest":
            return handlePermissionRequest(event, sessionId: sessionId)
        case "Stop":
            return handleStop(event, sessionId: sessionId)
        case "SessionStart":
            return handleSessionStart(event, sessionId: sessionId)
        case "Notification":
            return handleNotification(event, sessionId: sessionId)
        default:
            // Unknown event — just acknowledge
            updateSession(sessionId, lastSeen: Date())
            return ["continue": true]
        }
    }

    // MARK: - Event Handlers

    private func handleSessionStart(_ event: [String: Any], sessionId: String) -> [String: Any] {
        let activity = ClaudeActivity(
            id: sessionId,
            lastSeen: Date(),
            status: .idle
        )
        DispatchQueue.main.async {
            self.sessions[sessionId] = activity
        }
        return ["continue": true]
    }

    private func handlePreToolUse(_ event: [String: Any], sessionId: String) -> [String: Any] {
        let toolName = event["tool_name"] as? String ?? "unknown"
        let toolInput = event["tool_input"] as? [String: Any] ?? [:]

        // Update session status
        DispatchQueue.main.async {
            var session = self.sessions[sessionId] ?? ClaudeActivity(id: sessionId, lastSeen: Date(), status: .idle)
            session.toolName = toolName
            session.toolInput = self.summarizeInput(toolName, input: toolInput)
            session.lastSeen = Date()
            session.status = .running(tool: toolName)
            self.sessions[sessionId] = session

            // Track tool usage
            self.recentTools.append((date: Date(), session: sessionId, tool: toolName))
            if self.recentTools.count > 100 {
                self.recentTools.removeFirst(self.recentTools.count - 100)
            }
        }

        // Allow — we don't make permission decisions here, that's PermissionRequest's job
        return ["continue": true]
    }

    private func handlePostToolUse(_ event: [String: Any], sessionId: String) -> [String: Any] {
        DispatchQueue.main.async {
            if var session = self.sessions[sessionId] {
                session.lastSeen = Date()
                session.status = .idle
                session.toolName = nil
                session.toolInput = nil
                self.sessions[sessionId] = session
            }
        }
        return ["continue": true]
    }

    private func handlePermissionRequest(_ event: [String: Any], sessionId: String) -> [String: Any] {
        let toolName = event["tool_name"] as? String ?? "unknown"
        let toolInput = event["tool_input"] as? [String: Any] ?? [:]
        let requestId = "\(sessionId)_\(Int(Date().timeIntervalSince1970 * 1000))"

        let request = PermissionRequest(
            id: requestId,
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            timestamp: Date()
        )

        // Update session status
        DispatchQueue.main.async {
            var session = self.sessions[sessionId] ?? ClaudeActivity(id: sessionId, lastSeen: Date(), status: .idle)
            session.status = .waitingPermission
            session.toolName = toolName
            session.lastSeen = Date()
            self.sessions[sessionId] = session
            self.pendingPermissions.append(request)
        }

        // Block until user responds (up to 120 seconds)
        let semaphore = DispatchSemaphore(value: 0)
        var decision = "ask" // default: show normal Claude permission prompt

        lock.lock()
        permissionCallbacks[requestId] = { response in
            decision = response
            semaphore.signal()
        }
        lock.unlock()

        let timeout = semaphore.wait(timeout: .now() + 120)
        if timeout == .timedOut {
            decision = "ask" // fall through to normal prompt on timeout
        }

        lock.lock()
        permissionCallbacks.removeValue(forKey: requestId)
        lock.unlock()

        // Clean up
        DispatchQueue.main.async {
            self.pendingPermissions.removeAll { $0.id == requestId }
            if var session = self.sessions[sessionId] {
                session.status = .idle
                self.sessions[sessionId] = session
            }
        }

        // Return decision
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": decision
                ]
            ] as [String: Any]
        ]
    }

    private func handleStop(_ event: [String: Any], sessionId: String) -> [String: Any] {
        DispatchQueue.main.async {
            if var session = self.sessions[sessionId] {
                session.status = .stopped
                session.lastSeen = Date()
                session.toolName = nil
                self.sessions[sessionId] = session
            }
        }
        return ["continue": true]
    }

    private func handleNotification(_ event: [String: Any], sessionId: String) -> [String: Any] {
        updateSession(sessionId, lastSeen: Date())
        return ["continue": true]
    }

    // MARK: - Permission UI Actions

    /// Called from the UI when user approves a permission request
    public func approvePermission(_ requestId: String) {
        lock.lock()
        let callback = permissionCallbacks[requestId]
        lock.unlock()
        callback?("allow")
    }

    /// Called from the UI when user denies a permission request
    public func denyPermission(_ requestId: String) {
        lock.lock()
        let callback = permissionCallbacks[requestId]
        lock.unlock()
        callback?("deny")
    }

    // MARK: - Helpers

    private func updateSession(_ sessionId: String, lastSeen: Date) {
        DispatchQueue.main.async {
            if var session = self.sessions[sessionId] {
                session.lastSeen = lastSeen
                self.sessions[sessionId] = session
            } else {
                self.sessions[sessionId] = ClaudeActivity(id: sessionId, lastSeen: lastSeen, status: .idle)
            }
        }
    }

    private func summarizeInput(_ toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash", "bash":
            if let cmd = input["command"] as? String {
                let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 60 ? String(trimmed.prefix(60)) + "..." : trimmed
            }
        case "Read":
            return (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        case "Edit", "Write":
            return (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Agent":
            return input["description"] as? String ?? ""
        default:
            break
        }
        return ""
    }

    /// Active sessions sorted by last seen (most recent first)
    public var activeSessions: [ClaudeActivity] {
        let cutoff = Date().addingTimeInterval(-300) // hide sessions idle > 5 min
        return sessions.values
            .filter { $0.lastSeen > cutoff }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Garbage collect old sessions
    public func gc() {
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour
        DispatchQueue.main.async {
            self.sessions = self.sessions.filter { $0.value.lastSeen > cutoff }
            self.recentTools = self.recentTools.filter { $0.date > cutoff }
        }
    }
}
