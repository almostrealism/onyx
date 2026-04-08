//
// ClaudeSessionManager.swift
//
// Responsibility: Tracks active Claude Code CLI sessions reported via hook
//                 events, surfaces pending permission requests, and routes
//                 user approve/deny decisions back to the waiting hook.
// Scope: Per-window (lives on AppState).
// Threading: Hook events arrive on background queues; mutations to @Published
//            state are dispatched onto the main queue. An NSLock guards the
//            permissionCallbacks map shared with hook responders.
// Invariants:
//   - Each PermissionRequest.id maps to at most one callback in
//     permissionCallbacks; resolved requests remove their callback
//   - sessions[id].lastSeen monotonically advances per session
//   - recentTools is bounded (oldest entries pruned)
//

import Foundation
import Combine

// MARK: - Claude Code Session Tracking

/// Represents an active Claude Code session detected via hooks
public struct ClaudeActivity: Identifiable {
    /// Id.
    public let id: String          // session_id
    /// Tool name.
    public var toolName: String?   // current tool being used
    /// Tool input.
    public var toolInput: String?  // summary of tool input
    /// Last seen.
    public var lastSeen: Date
    /// Status.
    public var status: ClaudeStatus

    /// ClaudeStatus.
    public enum ClaudeStatus: Equatable {
        case idle
        case running(tool: String)
        case waitingPermission
        case stopped
    }
}

/// A pending permission request from Claude Code
public struct PermissionRequest: Identifiable {
    /// Id.
    public let id: String          // unique request ID
    /// Session id.
    public let sessionId: String
    /// Tool name.
    public let toolName: String
    /// Tool input.
    public let toolInput: [String: Any]
    /// Timestamp.
    public let timestamp: Date
    /// Resolved.
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

    /// When true, PreToolUse hooks block waiting for the user to approve or
    /// deny gated tool calls in the Onyx UI. When false (default), PreToolUse
    /// is informational only and Claude's normal terminal prompt runs.
    public var gatePermissions: Bool = false

    /// Tools that get gated when gatePermissions is on. Other tools (Read,
    /// Glob, Grep, etc) remain unblocked since they're side-effect-free.
    public var gatedTools: Set<String> = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Create a new instance.
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

        // If gating is on AND this is a gated tool, block waiting for the
        // user's decision in the Onyx UI. The response uses Claude Code's
        // PreToolUse hookSpecificOutput.permissionDecision shape, which is
        // the only documented way for a hook to override the default prompt.
        if gatePermissions && gatedTools.contains(toolName) {
            let decision = blockForPermission(sessionId: sessionId, toolName: toolName, toolInput: toolInput)
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": decision  // "allow" | "deny" | "ask"
                ] as [String: Any]
            ]
        }

        // Otherwise: informational only, let Claude's normal prompt run.
        return ["continue": true]
    }

    /// Block until the user approves or denies, or 120s elapses (then "ask").
    private func blockForPermission(sessionId: String, toolName: String, toolInput: [String: Any]) -> String {
        let requestId = "\(sessionId)_\(Int(Date().timeIntervalSince1970 * 1000))"
        let request = PermissionRequest(
            id: requestId,
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            timestamp: Date()
        )

        DispatchQueue.main.async {
            var session = self.sessions[sessionId] ?? ClaudeActivity(id: sessionId, lastSeen: Date(), status: .idle)
            session.status = .waitingPermission
            session.toolName = toolName
            session.lastSeen = Date()
            self.sessions[sessionId] = session
            self.pendingPermissions.append(request)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var decision = "ask"

        lock.lock()
        permissionCallbacks[requestId] = { response in
            decision = response
            semaphore.signal()
        }
        lock.unlock()

        let result = semaphore.wait(timeout: .now() + 120)
        if result == .timedOut { decision = "ask" }

        lock.lock()
        permissionCallbacks.removeValue(forKey: requestId)
        lock.unlock()

        DispatchQueue.main.async {
            self.pendingPermissions.removeAll { $0.id == requestId }
            if var session = self.sessions[sessionId] {
                session.status = .idle
                self.sessions[sessionId] = session
            }
        }

        return decision
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

    /// Legacy handler retained for backwards compatibility with any older
    /// hooks.json that still references PermissionRequest. Claude Code itself
    /// does NOT fire this event — permission decisions go through PreToolUse.
    private func handlePermissionRequest(_ event: [String: Any], sessionId: String) -> [String: Any] {
        let toolName = event["tool_name"] as? String ?? "unknown"
        let toolInput = event["tool_input"] as? [String: Any] ?? [:]
        let decision = blockForPermission(sessionId: sessionId, toolName: toolName, toolInput: toolInput)
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": decision]
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
