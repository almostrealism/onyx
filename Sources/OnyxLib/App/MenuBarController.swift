//
// MenuBarController.swift
//
// Responsibility: The menu bar item — an at-a-glance list of the sessions
//                 you're tracking and which of them an agent is trying to
//                 reach you about.
// Scope: App layer, shared singleton. Owns one NSStatusItem; reads
//        AppState, SessionNotesStore and AlertStore.
// Threading: main only. NSStatusItem and NSMenu are main-thread objects
//            and the menu is rebuilt from @Published state.
//
// Why this exists: the dock bounce tells you SOMETHING wants you, and
// macOS will not bounce at all while Onyx is frontmost. Neither tells you
// WHICH session — and answering that by switching to the app defeats the
// purpose when you're mid-thought in another window. So the answer lives
// outside the app: the alert titles are in the menu itself, not behind a
// submenu, because reading them without going anywhere is the whole
// feature.
//
// Only sessions you've said you care about appear — those with a note —
// plus any session with alerts, noted or not. A session that is alerting
// must never be invisible here; that would be the one case this is for.
//

import AppKit
import Combine

public final class MenuBarController: NSObject, NSMenuDelegate {
    public static let shared = MenuBarController()

    /// Bound to whichever window came up first. Weak, like AlertDelivery:
    /// the menu bar must not be the reason a window's state stays alive.
    private weak var appState: AppState?
    private var statusItem: NSStatusItem?
    private var watch: AnyCancellable?

    private override init() { super.init() }

    /// Called once per window; the first one wins. Sessions and alerts are
    /// app-wide, so any window's state answers the same questions.
    public func register(appState: AppState) {
        if self.appState == nil { self.appState = appState }
        guard watch == nil else { return }
        // The icon has to change the moment an alert arrives — that is the
        // signal the user is glancing up for. The MENU contents are built
        // on open (menuNeedsUpdate), so nothing else needs observing.
        watch = AlertStore.shared.$alerts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
    }

    // MARK: - Presence

    public func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { remove() }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshIcon()
    }

    private func remove() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    /// The glyph, and a count beside it when there's more than one.
    ///
    /// Template images only: the menu bar inverts them for light and dark
    /// and for the highlight state, and a coloured icon gets that wrong in
    /// at least one of the three. The BELL is the signal, not a tint.
    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let unseen = Self.unseenTotal()
        let symbol = unseen > 0 ? "bell.badge.fill" : "terminal"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Onyx")
        image?.isTemplate = true
        button.image = image
        button.title = unseen > 1 ? " \(unseen)" : ""
        button.toolTip = unseen > 0
            ? "\(unseen) unread from your agents"
            : "Onyx"
    }

    private static func unseenTotal() -> Int {
        AlertStore.shared.alerts.values.reduce(0) { $0 + $1.filter { !$0.seen }.count }
    }

    // MARK: - Rows

    /// One line's worth of what the menu shows, independent of AppKit so
    /// the ordering and filtering rules can be tested.
    public struct Row: Equatable {
        /// Storage key — what alerts and notes are filed under.
        public let key: String
        /// "trainer · mac-studio"
        public let label: String
        public let note: SessionNote?
        /// Newest first.
        public let alerts: [SessionAlert]

        public init(key: String, label: String, note: SessionNote?, alerts: [SessionAlert]) {
            self.key = key
            self.label = label
            self.note = note
            self.alerts = alerts
        }

        public var unseen: Int { alerts.filter { !$0.seen }.count }
        /// When this row last had something happen, for ordering.
        public var lastActivity: Date {
            max(alerts.first?.at ?? .distantPast, note?.updated ?? .distantPast)
        }
    }

    /// Which rows to show and in what order.
    ///
    /// Anything with neither a note nor an alert is dropped — this is a
    /// list of what you're tracking, not a session list; the app has one
    /// of those. Unseen alerts sort to the top, because the reason you
    /// opened this menu was the bounce.
    public static func rows(from candidates: [Row]) -> [Row] {
        candidates
            .filter { $0.note != nil || !$0.alerts.isEmpty }
            .sorted { a, b in
                if (a.unseen > 0) != (b.unseen > 0) { return a.unseen > 0 }
                return a.lastActivity > b.lastActivity
            }
    }

    /// Build the rows from live state.
    private func currentRows() -> [Row] {
        guard let appState else { return [] }
        var seenKeys = Set<String>()
        var rows: [Row] = []

        for session in appState.allSessions {
            let key = appState.storageKey(for: session)
            guard seenKeys.insert(key).inserted else { continue }
            let host = appState.host(for: session.source.hostID)
            let label = host.map { "\(session.displayLabel) · \($0.label)" } ?? session.displayLabel
            // storageKeys, not storageKey: a note or alert written before
            // the re-keying still lives under the legacy id.
            let alerts = appState.storageKeys(for: session)
                .flatMap { AlertStore.shared.alerts(for: $0) }
                .sorted { $0.at > $1.at }
            rows.append(Row(key: key, label: label,
                            note: appState.note(for: session), alerts: alerts))
        }
        return Self.rows(from: rows)
    }

    // MARK: - Building the menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = currentRows()
        let unseen = Self.unseenTotal()

        menu.addItem(header(unseen > 0 ? "ONYX — \(unseen) UNREAD" : "ONYX"))

        if rows.isEmpty {
            menu.addItem(dim("No session notes yet"))
        }

        for row in rows {
            let item = NSMenuItem(title: row.label, action: #selector(switchToSession(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = row.key
            if row.unseen > 0 {
                let bell = NSImage(systemSymbolName: "bell.badge.fill",
                                   accessibilityDescription: nil)
                bell?.isTemplate = true
                item.image = bell
            }
            item.toolTip = "Switch to this session"
            menu.addItem(item)

            // The alert text itself, in the menu. Not a submenu: finding
            // out which session is shouting shouldn't need a second click.
            for alert in row.alerts.prefix(3) where !alert.seen {
                menu.addItem(detail(Self.alertLine(alert), emphasised: true))
            }
            let moreUnseen = row.unseen - row.alerts.prefix(3).filter { !$0.seen }.count
            if moreUnseen > 0 {
                menu.addItem(detail("+ \(moreUnseen) more", emphasised: true))
            }
            if let note = row.note {
                menu.addItem(detail(Self.clip(note.text, 64), emphasised: false))
            }
        }

        // Alerts that named a session we couldn't find. Rare, and
        // invisible everywhere else in the menu bar — so if any exist,
        // they get a line rather than being silently dropped.
        let unattached = AlertStore.shared.alerts(for: nil).filter { !$0.seen }
        if !unattached.isEmpty {
            menu.addItem(.separator())
            menu.addItem(dim("Not matched to a session"))
            for alert in unattached.prefix(3) {
                menu.addItem(detail(Self.alertLine(alert), emphasised: true))
            }
        }

        menu.addItem(.separator())
        if unseen > 0 {
            let read = NSMenuItem(title: "Mark all as read", action: #selector(markAllRead),
                                  keyEquivalent: "")
            read.target = self
            menu.addItem(read)
        }
        let show = NSMenuItem(title: "Show Onyx", action: #selector(showOnyx), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
    }

    /// "15:04  Migration needs a decision" — time first, so a column of
    /// them reads as a timeline.
    static func alertLine(_ alert: SessionAlert) -> String {
        "\(stamp.string(from: alert.at))  \(clip(alert.title, 56))"
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 1.5,
        ])
        item.isEnabled = false
        return item
    }

    private func dim(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// An indented information line under a session. Disabled: there is
    /// nothing to click, and a menu that highlights unclickable rows
    /// invites clicking them.
    private func detail(_ text: String, emphasised: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: emphasised
                ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                : NSFont.systemFont(ofSize: 11),
            .foregroundColor: emphasised ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        item.indentationLevel = 1
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func switchToSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let appState else { return }
        activate()
        guard let session = appState.allSessions.first(where: {
            appState.storageKeys(for: $0).contains(key)
        }) else { return }
        appState.jumpToSession(session)
    }

    @objc private func markAllRead() {
        for key in AlertStore.shared.keysWithUnseen {
            AlertStore.shared.markSeen(for: key)
        }
        AlertDelivery.shared.clearAttention()
    }

    @objc private func showOnyx() {
        activate()
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        // A window that was hidden or ordered out stays that way on
        // activate alone.
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
