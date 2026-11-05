//
// AppState+SessionList.swift
//
// Responsibility: The sessions list — which sessions get a row (noted or
//                 matched to a Claude), in what order, and which of a
//                 row's Claudes speaks for it. One list for the detailed
//                 overlay, simple mode's side panel, the compact window
//                 and the session widget, so none can disagree.
//

import Foundation
import OnyxCore

/// One row of the sessions list: a session with a note, a session a
/// Claude is matched to, or both. Shared by the detailed overlay and
/// simple mode's side panel so the two can't disagree about which
/// sessions are listed or in what order.
struct SessionNoteEntry {
    let session: TmuxSession
    /// The user's note; nil for a session listed only for its Claudes.
    let note: SessionNote?
    /// Favorites-bar position (1-based) — nil when this session isn't a
    /// favorite of this window and therefore has no ⌘N shortcut.
    let shortcut: Int?
    /// The Claudes matched to this session, most recent first.
    let claudes: [ClaudeActivity]
    /// Terminal output or Claude hook, whichever came last.
    let lastActivity: Date?

    /// What the row is called: the note, else the session.
    var title: String { note?.text ?? session.displayLabel }

    /// The Claude to speak for the row: waiting for permission first,
    /// then running, then the most recently heard from.
    static func lead(of claudes: [ClaudeActivity]) -> ClaudeActivity? {
        func rank(_ c: ClaudeActivity) -> Int {
            switch c.status {
            case .waitingPermission: return 0
            case .running: return 1
            case .idle, .stopped: return 2
            }
        }
        return claudes.min { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.lastSeen > b.lastSeen
        }
    }

    /// The lead Claude's activity in words.
    static func summary(of activity: ClaudeActivity) -> String {
        switch activity.status {
        case .running(let tool): return "running \(tool)"
        case .waitingPermission: return "waiting for permission"
        case .idle: return "idle"
        case .stopped: return "waiting for you"
        }
    }
}

/// Every session worth a row: the noted ones, because a note is the user
/// saying "I care about this one", and the matched ones, because a Claude
/// at work there says the same.
///
/// Ordered to match the favorites bar at the bottom of the window: this
/// window's favorites first in bar order, then the rest by most recent
/// activity. Free function rather than a method so simple mode gets the
/// identical ordering without inheriting the whole section view.
func orderedSessionNotes(appState: AppState,
                         store: SessionNotesStore = .shared,
                         matches: ClaudeMatches? = nil) -> [SessionNoteEntry] {
    let matches = matches ?? appState.claudeMatches
    let noted = store.activeNotes(in: appState.allSessions,
                                  keys: { appState.storageKeys(for: $0) })
    let notes = Dictionary(noted.map { ($0.session.id, $0.note) },
                           uniquingKeysWith: { first, _ in first })
    let listed = appState.allSessions.filter {
        notes[$0.id] != nil || !matches.claudes(in: $0.id).isEmpty
    }
    var seen = Set<String>()
    let sessions = listed.filter { seen.insert($0.id).inserted }
    func entry(_ session: TmuxSession, shortcut: Int?) -> SessionNoteEntry {
        SessionNoteEntry(session: session, note: notes[session.id], shortcut: shortcut,
                         claudes: matches.claudes(in: session.id),
                         lastActivity: appState.lastActivity(for: session, in: matches))
    }

    let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var rows: [SessionNoteEntry] = []
    var placed = Set<String>()
    for (idx, fav) in appState.favoriteSessions.enumerated() {
        guard let hit = byID[fav.id] else { continue }
        rows.append(entry(hit, shortcut: idx < 9 ? idx + 1 : nil))
        placed.insert(fav.id)
    }
    let rest = sessions
        .filter { !placed.contains($0.id) }
        .map { entry($0, shortcut: nil) }
        .sorted { ($0.lastActivity ?? $0.note?.updated ?? .distantPast)
                    > ($1.lastActivity ?? $1.note?.updated ?? .distantPast) }
    rows.append(contentsOf: rest)
    return rows
}
