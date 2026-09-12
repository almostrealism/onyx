//
// AlertDelivery.swift
//
// Responsibility: Turning "an agent wants the user's attention" into the
//                 things that actually get it — a stored alert, an
//                 indicator on the right session, a dock bounce, an OS
//                 notification.
// Scope: Shared singleton; the MCP server calls in from whatever thread
//        a request arrived on.
//
// The two flags are named for INTENT, not for macOS. `urgent` means
// "interrupt me", `external` means "tell me even when Onyx isn't in
// front". What a platform does with those is its own business; on a Mac
// it's dock bouncing and Notification Center, and the tool description
// says so rather than the vocabulary.
//

import Foundation
import AppKit
#if canImport(UserNotifications)
import UserNotifications
#endif

public final class AlertDelivery {
    public static let shared = AlertDelivery()

    /// Set at launch. Weak: the delivery path must never be the reason a
    /// window's state stays alive.
    private weak var appState: AppState?
    private let lock = NSLock()

    private init() {
        // macOS cancels an attention request the moment the app is
        // activated, but it doesn't tell us — so the token we're holding
        // becomes a dead handle. Left in place it reads as "already
        // bouncing" and every LATER urgent alert is silently swallowed:
        // you get one bounce per app launch. Drop the token when the user
        // comes back, which is exactly when the request ended.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.attentionToken = nil
        }
    }

    public func register(appState: AppState) {
        lock.lock()
        // First window wins. Alerts are app-wide — they attach to
        // sessions, not to windows — so binding to whichever window
        // opened first is as good as any and stops later windows
        // re-pointing it mid-flight.
        if self.appState == nil { self.appState = appState }
        lock.unlock()
    }

    /// Deliver an alert. Returns what happened, so the tool can tell the
    /// agent whether its aim landed rather than silently swallowing it.
    @discardableResult
    public func deliver(title: String, body: String?,
                        urgent: Bool, external: Bool,
                        user: String?, host: String?, session: String?) -> Outcome {
        let target = (user == nil && host == nil && session == nil)
            ? nil
            : SessionAlert.Target(user: user, host: host, session: session)

        let match = resolveSession(user: user, host: host, session: session)
        let alert = SessionAlert(title: title, body: body, urgent: urgent,
                                 external: external, sessionKey: match.key, target: target)
        AlertStore.shared.record(alert)

        if urgent { bounce() }
        if external { postExternal(alert) }

        return Outcome(
            attachedTo: match.key,
            // An alert that named a session we can't find still gets
            // delivered — it just lands in the unattached list. Saying so
            // lets the agent correct itself next time.
            matchedTarget: target == nil ? nil : (match.key != nil),
            ignoredUser: match.ignoredUser
        )
    }

    public struct Outcome {
        public let attachedTo: String?
        /// nil when no target was given; false when one was and nothing
        /// matched it.
        public let matchedTarget: Bool?
        /// True when host and session picked out one session but the user
        /// named didn't match it — the `su` case.
        public let ignoredUser: Bool

        public init(attachedTo: String?, matchedTarget: Bool?, ignoredUser: Bool = false) {
            self.attachedTo = attachedTo
            self.matchedTarget = matchedTarget
            self.ignoredUser = ignoredUser
        }
    }

    // MARK: - Routing

    private func resolveSession(user: String?, host: String?, session: String?)
        -> AlertRouting.Match {
        lock.lock(); let state = appState; lock.unlock()
        guard let state else { return AlertRouting.Match(key: nil) }

        var candidates: [(key: String, user: String, host: String, session: String)] = []
        // Snapshot on main — allSessions and hosts are @Published.
        let snapshot: ([TmuxSession], [HostConfig]) = DispatchQueue.main.sync {
            (state.allSessions, state.hosts)
        }
        for s in snapshot.0 {
            let hostID = s.source.hostID
            guard let cfg = snapshot.1.first(where: { $0.id == hostID })
                    ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil) else { continue }
            candidates.append((
                key: DispatchQueue.main.sync { state.storageKey(for: s) },
                user: SessionIdentity.effectiveUser(for: cfg),
                host: SessionIdentity.normalizedHost(for: cfg),
                session: s.name
            ))
        }
        return AlertRouting.match(user: user, host: host, session: session,
                                  candidates: candidates)
    }

    // MARK: - Getting noticed

    private var attentionToken: Int?

    /// macOS's answer to "urgent". `.criticalRequest` keeps bouncing
    /// until Onyx is activated — one bounce is easy to miss from another
    /// app, which is the only situation where this matters. Nothing
    /// bounces when Onyx is already frontmost; the indicator is right
    /// there.
    private func bounce() {
        DispatchQueue.main.async {
            guard !NSApp.isActive else { return }
            if self.attentionToken == nil {
                self.attentionToken = NSApp.requestUserAttention(.criticalRequest)
            }
        }
    }

    /// Called when the user looks at their alerts — stop bouncing.
    public func clearAttention() {
        DispatchQueue.main.async {
            guard let token = self.attentionToken else { return }
            NSApp.cancelUserAttentionRequest(token)
            self.attentionToken = nil
        }
    }

    /// macOS's answer to "external". Guarded on a bundle identifier:
    /// UNUserNotificationCenter traps in a process that isn't a real
    /// bundle, which is every `swift run`.
    private func postExternal(_ alert: SessionAlert) {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let body = alert.body { content.body = body }
        else if let label = alert.target?.label, !label.isEmpty { content.body = label }
        content.sound = alert.urgent ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
        #endif
    }

    /// Ask once, so the first external alert isn't silently dropped.
    public func requestExternalPermissionIfPossible() {
        #if canImport(UserNotifications)
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }
}
