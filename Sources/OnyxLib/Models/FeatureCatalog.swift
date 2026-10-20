//
// FeatureCatalog.swift
//
// Responsibility: The one list of capabilities Onyx points people at —
//                 what each is, the keys for it, and where on screen it
//                 lives — and the rules for which to show.
// Scope: Model. Pure; FeatureTipStore remembers what each person has seen.
//
// Why this exists: most feature requests we get are for things that
// already ship. Release notes don't reach people, and a list of keys
// answers "what does ⌘J do", not "what can I do here". So a feature is
// pointed at in two ways, both driven by this list:
//
//   - What's New: once, after an update, a card naming what arrived since
//     this person last looked. New users get the tour instead.
//   - A tip in place: one line, at the spot where the feature is used
//     ("NEW · ⌘V pastes files copied in Finder"), until the person uses
//     it or closes the tip. One tip per place at a time, oldest first, so
//     a release with five file-browser features doesn't bury the browser.
//
// Adding a feature: append an entry. Give it a `place` if there's a spot
// on screen where the tip makes sense, and call `FeatureTipStore.used(_:)`
// where the feature is actually used, so its tip retires itself.
//

import Foundation

/// Where a feature's tip is shown.
public enum FeaturePlace: String, Codable, CaseIterable {
    /// The status bar under the terminal.
    case terminal
    /// The monitor's agenda pane (both layouts).
    case monitorAgenda
    /// The file browser's listing.
    case fileBrowser
    /// A file open in the file browser.
    case fileViewer
}

public struct Feature: Identifiable, Equatable {
    /// Stable forever: it is what a person's "seen" record is keyed by.
    public let id: String
    /// The release that brought it.
    public let since: String
    /// What's New's heading.
    public let title: String
    /// What's New's sentence or two.
    public let detail: String
    /// The tip, short enough for one line.
    public let tip: String
    /// Keys, shown as chips.
    public let keys: [String]
    /// Where the tip goes; nil for What's New only.
    public let place: FeaturePlace?

    public init(id: String, since: String, title: String, detail: String,
                tip: String, keys: [String] = [], place: FeaturePlace?) {
        self.id = id
        self.since = since
        self.title = title
        self.detail = detail
        self.tip = tip
        self.keys = keys
        self.place = place
    }
}

public enum FeatureCatalog {

    /// Oldest first — the order What's New lists them in and the order a
    /// place's tips take turns.
    public static let all: [Feature] = [
        Feature(id: "terminal.shift-return", since: "0.20",
                title: "Shift-Return makes a new line in Claude Code",
                detail: "Instead of submitting. Write a multi-line prompt the way you would anywhere else.",
                tip: "⇧↩ makes a new line in Claude Code", keys: ["⇧↩"],
                place: .terminal),
        Feature(id: "terminal.ctrl-tab", since: "0.20",
                title: "⌃⇥ cycles sessions — ⇧⇥ belongs to the terminal now",
                detail: "Shift-Tab goes to whatever's running, so Claude Code's permission-mode switch works. Want Shift-Tab to cycle sessions again? Settings → General → Keyboard.",
                tip: "⌃⇥ cycles sessions · ⇧⇥ goes to the terminal", keys: ["⌃⇥"],
                place: .terminal),
        Feature(id: "monitor.calendar", since: "0.20",
                title: "Today's calendar in the monitor",
                detail: "The Reminders pane can show today's calendar instead — what's on now is lit, what's over is dimmed. Press A with the monitor up, or click CALENDAR in the pane's header.",
                tip: "A switches this list to today's calendar", keys: ["A"],
                place: .monitorAgenda),
        Feature(id: "files.paste", since: "0.20",
                title: "Paste files into the file browser",
                detail: "Copy files or folders in Finder, click into the file browser and press ⌘V. They upload to the folder shown, the same as dropping them there.",
                tip: "⌘V pastes files copied in Finder into this folder", keys: ["⌘V"],
                place: .fileBrowser),
        Feature(id: "files.tree", since: "0.20",
                title: "The file browser as a tree",
                detail: "The tree button above the listing shows folders expanding in place instead of one folder at a time.",
                tip: "The tree button above shows this folder as a tree", keys: [],
                place: .fileBrowser),
        Feature(id: "files.edit", since: "0.20",
                title: "Edit a file and save it back to the host",
                detail: "Open a file, press Edit, change it, ⌘S. If someone changed it on the host meanwhile, Onyx asks before overwriting. Permissions and symlinks are kept.",
                tip: "Edit opens this file full-window · ⌘S saves it to the host", keys: ["⌘S"],
                place: .fileViewer),
        Feature(id: "panel.divider", since: "0.20",
                title: "Resize the side panel",
                detail: "Drag the grip between the terminal and the panel, or press ⌘\\ to step through widths. Each window remembers its own width. Double-click the grip for the default.",
                tip: "Drag the grip to resize · ⌘\\ steps through widths", keys: ["⌘\\"],
                place: nil),
        Feature(id: "monitor.d-opens-panel", since: "0.20",
                title: "D opens the side panel from anywhere in the monitor",
                detail: "In the detailed layout it switches to the simple one with the panel showing, instead of quietly changing a setting you can't see.",
                tip: "D shows the side panel", keys: ["D"],
                place: nil),
    ]

    public static func feature(_ id: String) -> Feature? {
        all.first { $0.id == id }
    }

    /// What What's New should list: everything not yet announced.
    public static func unannounced(announced: Set<String>,
                                   in catalog: [Feature] = all) -> [Feature] {
        catalog.filter { !announced.contains($0.id) }
    }

    /// The tip to show at `place`, if any: the oldest one not yet retired.
    public static func tip(at place: FeaturePlace, retired: Set<String>,
                           in catalog: [Feature] = all) -> Feature? {
        catalog.first { $0.place == place && !retired.contains($0.id) }
    }
}
