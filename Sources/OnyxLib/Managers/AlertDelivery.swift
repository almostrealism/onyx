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
// The agent says one thing — `urgent`, meaning "this needs a person" —
// and the PERSON'S settings decide how far it goes on this Mac: whether it
// reaches Notification Center, and whether it reaches their phone. The
// agent used to hold a second flag for that. It was the wrong hands: an
// agent can't know which machine the user is at, and reliably reaching
// someone is a property of their setup, not of each call.
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
    /// `at` is when the agent SENT it, which is not always when it
    /// arrived: an alert the bridge couldn't deliver is queued and
    /// replayed later, and stamping it with the delivery time would make
    /// it say "finished at 9am" about work that finished at 2am.
    public func deliver(title: String, body: String?,
                        urgent: Bool,
                        user: String?, host: String?, session: String?,
                        at: Date = Date()) -> Outcome {
        let target = (user == nil && host == nil && session == nil)
            ? nil
            : SessionAlert.Target(user: user, host: host, session: session)

        let (match, policy) = resolveSession(user: user, host: host, session: session)
        let alert = SessionAlert(at: at, title: title, body: body, urgent: urgent,
                                 sessionKey: match.key, target: target)
        AlertStore.shared.record(alert)

        if urgent { bounce() }
        // This Mac's own rule for what leaves the app.
        if policy.allows(urgent: urgent) { postExternal(alert) }
        // And off the Mac entirely, if the user has set that up. A Mac
        // notification never reaches an Apple Watch — the watch mirrors a
        // phone — so this is the only path from "an agent is blocked" to
        // "my wrist buzzed". The forwarder has its own threshold.
        AlertForwarder.shared.consider(alert, sessionLabel: target?.label)

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

    /// The routing match, plus this Mac's delivery policy — read in the
    /// same hop to main, since both live on AppState.
    private func resolveSession(user: String?, host: String?, session: String?)
        -> (AlertRouting.Match, ExternalDelivery) {
        lock.lock(); let state = appState; lock.unlock()
        guard let state else { return (AlertRouting.Match(key: nil), .urgentOnly) }

        // ONE hop to main, not one per session.
        //
        // This ran a `main.sync` inside the loop to fetch each storage
        // key, so a host with twenty sessions made twenty round trips —
        // on the connection's queue, while an agent waits for its notify
        // to return, and each one pausing behind whatever the UI happens
        // to be doing. The whole snapshot is cheap; taking it in pieces
        // was the expensive part.
        let (candidates, policy): ([(key: String, user: String, host: String, session: String)], ExternalDelivery)
            = DispatchQueue.main.sync {
                (state.allSessions.compactMap { session in
                    let hostID = session.source.hostID
                    guard let cfg = state.hosts.first(where: { $0.id == hostID })
                            ?? (hostID == HostConfig.localhostID ? HostConfig.localhost : nil)
                    else { return nil }
                    return (key: state.storageKey(for: session),
                            user: SessionIdentity.effectiveUser(for: cfg),
                            host: SessionIdentity.normalizedHost(for: cfg),
                            session: session.name)
                }, state.appearance.externalDelivery)
            }
        return (AlertRouting.match(user: user, host: host, session: session,
                                   candidates: candidates), policy)
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
        // The bundle check alone isn't enough: the xctest runner HAS an
        // identifier, and UNUserNotificationCenter still traps in it
        // ("bundleProxyForCurrentProcess is nil"). This never fired from
        // tests while `external` defaulted to false; with urgent the
        // default and delivery decided by settings, it does.
        guard Bundle.main.bundleIdentifier != nil,
              NSClassFromString("XCTest") == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let body = alert.body {
            content.body = body
        } else if let label = alert.target?.label, !label.isEmpty {
            content.body = label
        }
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
