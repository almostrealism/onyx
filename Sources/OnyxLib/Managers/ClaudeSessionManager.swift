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
import AppKit

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
    /// Where it's running, as its hooks report it. Nil from a bridge
    /// older than protocol 4, which didn't say.
    public var origin: HookOrigin? = nil

    /// ClaudeStatus.
    public enum ClaudeStatus: Equatable {
        case idle
        case running(tool: String)
        case waitingPermission
        case stopped
    }
}

/// Where a hook event came from: the machine, the account, and the tmux
/// session — as the bridge on that machine saw them.
public struct HookOrigin: Equatable, Hashable {
    public let machine: String
    public let user: String?
    public let session: String?
    /// The hook's ancestor pids, nearest first — sent instead of a session
    /// when the hook couldn't ask tmux (Claude under `su -` in another
    /// account's tmux). Onyx looks the pane up; see `TmuxPaneLookup`.
    public let pids: [Int]

    public init(machine: String, user: String? = nil, session: String? = nil, pids: [Int] = []) {
        self.machine = machine
        self.user = user
        self.session = session
        self.pids = pids
    }

    /// From the event's `onyx_origin`.
    public init?(_ raw: Any?) {
        guard let dict = raw as? [String: Any],
              let machine = dict["machine"] as? String, !machine.isEmpty else { return nil }
        self.init(machine: machine, user: dict["user"] as? String, session: dict["session"] as? String,
                  pids: (dict["pids"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? [])
    }

    /// The same origin, with the session Onyx found for it.
    public func with(session: String) -> HookOrigin {
        HookOrigin(machine: machine, user: user, session: session, pids: pids)
    }

    /// Whether Onyx should look the session up.
    public var needsPaneLookup: Bool { session == nil && !pids.isEmpty }

    /// "user@machine", the identity hooks are configured for.
    public var account: String { user.map { "\($0)@\(machine)" } ?? machine }

    /// "user@machine · session" — what a person would recognize.
    public var label: String { session.map { "\(account) · \($0)" } ?? account }
}

/// Every machine/account that has sent hook events, and when. The first
/// question when a host's Claude sessions are missing is "has Onyx heard
/// from its hooks at all?" — this is the answer.
public struct HookSource: Identifiable, Equatable {
    public var id: String { account }
    public let account: String
    public var lastEvent: String
    public var lastAt: Date
    public var events: Int
    public var sessions: Set<String>
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

    /// Outstanding dock-bounce request, so it can be cancelled when the
    /// agent stops waiting.
    private var attentionToken: Int?
    @Published public var recentTools: [(date: Date, session: String, tool: String)] = []

    private let lock = NSLock()
    /// Completion handlers waiting for permission responses, keyed by request ID
    private var permissionCallbacks: [String: (String) -> Void] = [:]

    /// When true, PermissionRequest hooks block waiting for the user to
    /// approve/deny in the Onyx UI banner. When false (default), Claude's
    /// normal in-terminal permission prompt is used.
    ///
    /// Unlike the earlier approach that gated ALL tool calls via PreToolUse,
    /// PermissionRequest only fires when Claude would actually show a prompt
    /// — meaning auto-allowed tools (Read, Grep, etc., plus anything the
    /// user's settings.json has explicitly allowed) never trigger it. This
    /// naturally respects the user's existing permission configuration.
    public var gatePermissions: Bool = false

    /// Hook sources heard from since launch, keyed by account.
    @Published public private(set) var hookSources: [String: HookSource] = [:]
    /// Hook events that arrived without an origin — from bridges older
    /// than protocol 4. Counted so "nothing heard" and "heard, but can't
    /// say from where" aren't confused.
    @Published public private(set) var anonymousHookEvents = 0

    /// The app's one session list. Claude sessions are facts about hosts,
    /// not windows, and every hook event reaches one server.
    public static let shared = ClaudeSessionManager()

    /// Create a new instance.
    public init() {}

    // MARK: - Finding the tmux session a hook couldn't name

    /// Asks a host's tmux which session an origin's pids belong to, and
    /// calls back on main with the name or nil. Set once by the first
    /// window (AppState owns the SSH); see `registerPaneLookup`.
    public typealias PaneLookup = (HookOrigin, @escaping (String?) -> Void) -> Void
    private var paneLookup: PaneLookup?
    private weak var paneLookupOwner: AnyObject?

    /// Per Claude session: what the lookup found, and when it last tried.
    /// Keyed by session id, not pids: Claude starts each hook through a
    /// fresh shell, so the nearest pid changes on every event.
    private struct PaneLookupState {
        var session: String?
        var tries = 0
        var lastTry: Date
        var inFlight = false
    }
    private var paneLookups: [String: PaneLookupState] = [:]
    /// A miss is retried this often, this many times — the session may
    /// not be listed yet, or the host may be reconnecting. Past that it is
    /// left unnamed rather than costing an ssh call per minute forever.
    static let paneRetryInterval: TimeInterval = 60
    static let paneMaxTries = 3

    /// Install the lookup. First owner wins; a later one takes over only
    /// once the first is gone (its window closed).
    public func registerPaneLookup(owner: AnyObject, _ lookup: @escaping PaneLookup) {
        DispatchQueue.main.async {
            guard self.paneLookup == nil || self.paneLookupOwner == nil else { return }
            self.paneLookupOwner = owner
            self.paneLookup = lookup
        }
    }

    /// The origin to show for `sessionId`: as reported, or with the
    /// session the lookup found. Starts a lookup when one is due. Main only.
    private func resolvedOrigin(_ origin: HookOrigin, sessionId: String, at now: Date) -> HookOrigin {
        guard origin.needsPaneLookup else { return origin }
        if let found = paneLookups[sessionId]?.session { return origin.with(session: found) }
        guard let lookup = paneLookup, paneLookupOwner != nil else { return origin }
        var state = paneLookups[sessionId] ?? PaneLookupState(lastTry: .distantPast)
        guard !state.inFlight, state.tries < Self.paneMaxTries,
              now.timeIntervalSince(state.lastTry) >= Self.paneRetryInterval else { return origin }
        state.inFlight = true
        state.tries += 1
        state.lastTry = now
        paneLookups[sessionId] = state
        lookup(origin) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                self.paneLookups[sessionId]?.inFlight = false
                guard let found else { return }
                self.paneLookups[sessionId]?.session = found
                if let current = self.sessions[sessionId]?.origin, current.session == nil {
                    self.sessions[sessionId]?.origin = current.with(session: found)
                }
            }
        }
        return origin
    }

    /// Note where an event came from. Public for tests.
    public func recordOrigin(_ origin: HookOrigin?, event: String, sessionId: String, at: Date = Date()) {
        DispatchQueue.main.async {
            guard let reported = origin else {
                self.anonymousHookEvents += 1
                return
            }
            let origin = self.resolvedOrigin(reported, sessionId: sessionId, at: at)
            var source = self.hookSources[origin.account]
                ?? HookSource(account: origin.account, lastEvent: event, lastAt: at, events: 0, sessions: [])
            source.lastEvent = event
            source.lastAt = at
            source.events += 1
            source.sessions.insert(sessionId)
            self.hookSources[origin.account] = source
            // The handler's own update is queued after this one, so the
            // session may not exist yet.
            self.sessions[sessionId, default: ClaudeActivity(id: sessionId, lastSeen: at, status: .idle)]
                .origin = origin
        }
    }

    // MARK: - Hook Event Processing

    /// Process a hook event from Claude Code. Returns a JSON response string.
    /// For permission requests, this blocks until the user responds via the UI.
    public func processHookEvent(_ event: [String: Any]) -> [String: Any] {
        let eventName = event["hook_event_name"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? "unknown"
        // Recorded BEFORE the handler: a PermissionRequest blocks for up
        // to two minutes, and that is exactly when you want to see which
        // machine is asking.
        recordOrigin(HookOrigin(event["onyx_origin"]), event: eventName, sessionId: sessionId)

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
        DispatchQueue.main.async {
            // A fresh start, but keep where it's running: the origin was
            // recorded just before this.
            var activity = ClaudeActivity(id: sessionId, lastSeen: Date(), status: .idle)
            activity.origin = self.sessions[sessionId]?.origin
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

        // Always defer — never block. Permission gating is handled by the
        // PermissionRequest hook (which only fires when Claude would actually
        // prompt the user, respecting their existing allow/deny rules).
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "defer"
            ] as [String: Any]
        ]
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
            self.beginAttentionRequest()
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
            self.endAttentionRequestIfIdle()
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

    /// Handle a PermissionRequest event. This fires ONLY when Claude Code
    /// would normally show a terminal permission prompt — meaning auto-allowed
    /// tools and explicitly-allowed commands DON'T trigger it. This naturally
    /// respects the user's existing permission configuration.
    ///
    /// When gatePermissions is on, block and surface the request in the Onyx
    /// UI. When off, return immediately and let the normal prompt appear.
    private func handlePermissionRequest(_ event: [String: Any], sessionId: String) -> [String: Any] {
        let toolName = event["tool_name"] as? String ?? "unknown"
        let toolInput = event["tool_input"] as? [String: Any] ?? [:]

        guard gatePermissions else {
            // Not gating — let the normal Claude terminal prompt handle it.
            return ["continue": true]
        }

        let decision = blockForPermission(sessionId: sessionId, toolName: toolName, toolInput: toolInput)
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "permissionDecision": decision  // "allow" | "deny" | "ask"
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

// MARK: - Getting noticed

extension ClaudeSessionManager {

    /// Bounce the dock icon while an agent is blocked on a decision.
    ///
    /// A blocked agent nobody notices is the exact problem this app
    /// exists to solve — the request has a 120-second timeout, so not
    /// seeing it doesn't just delay the work, it abandons it.
    ///
    /// `.criticalRequest` keeps bouncing until the app is activated,
    /// which is right here: one bounce is easy to miss while you're in
    /// another window, and that's precisely when this happens. Nothing
    /// bounces when Onyx is already the active app — you can see the
    /// banner.
    func beginAttentionRequest() {
        guard !NSApp.isActive, attentionToken == nil else { return }
        attentionToken = NSApp.requestUserAttention(.criticalRequest)
    }

    /// Stop bouncing once nothing is waiting. Called when a request is
    /// answered OR times out, so an abandoned request doesn't leave the
    /// dock jumping forever.
    func endAttentionRequestIfIdle() {
        guard pendingPermissions.isEmpty, let token = attentionToken else { return }
        NSApp.cancelUserAttentionRequest(token)
        attentionToken = nil
    }
}
