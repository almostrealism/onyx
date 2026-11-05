//
// AppState+SessionWidget.swift
//
// Responsibility: Feed the session widget — turn the sessions list into
//                 the snapshot the widget reads, write it to the shared
//                 App Group container, and ask WidgetKit to reload when a
//                 change is worth one (`SessionWidgetPacing`). And open a
//                 session from the widget's `onyx://session?id=` links.
// Scope: The periodic work is app-wide, run by one window at a time.
//

import AppKit
import WidgetKit
import OnyxCore
import OnyxWidgetKit

extension AppState {

    /// How often the sessions list is turned into a snapshot. Cheap: no
    /// remote call, and the file is written only when something changed.
    static let sessionWidgetTick: TimeInterval = 10
    /// The most rows any widget size shows.
    static let sessionWidgetRows = 12

    /// The widget's rows: the sessions list, as this window orders it.
    func sessionWidgetRows() -> [SessionWidgetRow] {
        Self.widgetRows(orderedSessionNotes(appState: self))
    }

    static func widgetRows(_ entries: [SessionNoteEntry]) -> [SessionWidgetRow] {
        entries.prefix(sessionWidgetRows).map { entry in
            let lead = SessionNoteEntry.lead(of: entry.claudes)
            let claude: SessionWidgetRow.Claude? = lead.map {
                switch $0.status {
                case .running: return .running
                case .waitingPermission: return .waitingPermission
                case .stopped: return .waitingForYou
                case .idle: return .idle
                }
            }
            // A noted row's title is its note, so its second line says
            // where it is; a row listed for its Claude says what it's doing.
            let detail = lead.map(SessionNoteEntry.summary(of:))
                ?? (entry.note != nil ? entry.session.displayLabel : nil)
            return SessionWidgetRow(id: entry.session.id, title: entry.title, detail: detail,
                                    claude: claude, moreClaudes: max(0, entry.claudes.count - 1),
                                    lastActivity: entry.lastActivity, shortcut: entry.shortcut)
        }
    }

    /// Start feeding the widget, once per app. Only a build signed by a
    /// team has a container to share; any other does nothing.
    func startSessionWidget() {
        guard NSClassFromString("XCTest") == nil, !SessionWidgetWork.started,
              let url = SessionWidgetStore.fileURL() else { return }
        SessionWidgetWork.started = true
        SessionWidgetWork.fileURL = url
        sessionWidgetStep()
        Timer.scheduledTimer(withTimeInterval: Self.sessionWidgetTick, repeats: true) { _ in
            // Whichever window is still open does the work.
            ShortcutManager.anyAppState()?.sessionWidgetStep()
        }
    }

    func sessionWidgetStep() {
        guard let url = SessionWidgetWork.fileURL else { return }
        let now = Date()
        let rows = sessionWidgetRows()
        let decision = SessionWidgetWork.pacing.step(rows, now: now)
        guard decision.write else { return }
        let snapshot = SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now, rows: rows)
        DispatchQueue.global(qos: .utility).async {
            do {
                try SessionWidgetStore.write(snapshot, to: url)
            } catch {
                OnyxLog.store.error("session widget: couldn't write \(url.path): \(error.localizedDescription)")
                return
            }
            if decision.reload {
                WidgetCenter.shared.reloadTimelines(ofKind: SessionWidgetStore.kind)
            }
        }
    }
}

/// The app-wide half of the widget's feed. Main thread only.
enum SessionWidgetWork {
    static var started = false
    static var fileURL: URL?
    static var pacing = SessionWidgetPacing()
}

// MARK: - Opening a session from the widget

/// `onyx://session?id=…`: bring Onyx forward on that session.
///
/// A click on the widget can launch Onyx, and then the link arrives before
/// any window has listed its sessions — so an id no window knows yet is
/// kept and tried again for a while, rather than dropped.
public enum SessionLinkRouter {

    private static var pending: (id: String, until: Date)?
    private static var retryTimer: Timer?

    /// Handle `kAEGetURL`. Installed in `applicationWillFinishLaunching`,
    /// before AppKit (and SwiftUI, which would open a new window for it)
    /// could take the event.
    public static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared, andSelector: #selector(Handler.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    public static func open(_ url: URL) {
        guard let id = SessionLink.sessionID(in: url) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !tryOpen(id) {
            pending = (id, Date().addingTimeInterval(30))
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                guard let wanted = pending, Date() < wanted.until else {
                    pending = nil; timer.invalidate(); return
                }
                if tryOpen(wanted.id) { pending = nil; timer.invalidate() }
            }
        }
    }

    /// The key window if it has the session, else any window that does.
    private static func tryOpen(_ id: String) -> Bool {
        let states = ShortcutManager.registeredWindows()
        let ordered = states.filter { $0.window.isKeyWindow } + states.filter { !$0.window.isKeyWindow }
        for (window, state) in ordered {
            guard let session = state.allSessions.first(where: { $0.id == id }) else { continue }
            window.makeKeyAndOrderFront(nil)
            state.jumpToSession(session, dismissIfAlreadyActive: false)
            return true
        }
        return false
    }

    private final class Handler: NSObject {
        static let shared = Handler()
        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                  let url = URL(string: text) else { return }
            SessionLinkRouter.open(url)
        }
    }
}
