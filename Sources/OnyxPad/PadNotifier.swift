//
// PadNotifier.swift
//
// Responsibility: Local notifications while Onyx is open but not in front
//                 — a terminal's bell (an agent finishing, a build done),
//                 a terminal whose connection went, an agent's alert.
// Scope: Service. iOS only in effect: on the Mac (tests) it records and
//        posts nothing.
//
// docs/ios-plan.md: alerts reach an iPad only while the app runs. In front,
// what happened is on screen; a notification is for the moment you're in
// another app (Stage Manager, Split View) or just switched away.
//

import Foundation
#if os(iOS)
import UserNotifications
#endif

public enum PadNotifier {

    /// Whether the app is in front; set by PadModel.
    public static var isFrontmost = true
    /// What would have been posted, for tests and the Mac build.
    public private(set) static var posted: [(title: String, body: String)] = []

    private static var asked = false

    /// Asked once, when the first terminal opens — the moment the reason
    /// for asking is on screen, not at launch.
    public static func requestPermission() {
        guard !asked else { return }
        asked = true
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        #endif
    }

    /// Post, unless the app is in front (where it's already on screen) —
    /// `evenInFront` for what must be seen regardless.
    public static func post(title: String, body: String, id: String, evenInFront: Bool = false) {
        guard evenInFront || !isFrontmost else { return }
        posted.append((title, body))
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id)-\(UUID())",
                                                                     content: content, trigger: nil))
        #endif
    }

    static func reset() { posted = [] }
}
