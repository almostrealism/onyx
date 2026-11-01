import SwiftUI
import OnyxCore
import OnyxUI

struct ClaudeSessionsSection: View {
    @ObservedObject var appState: AppState
    /// Most sessions listed before "+N more". The list lives in a column
    /// shared with other sections, and an uncapped list of a busy fleet's
    /// agents pushed everything below it off the screen. Permission
    /// requests are never capped: each one is an agent blocked on you.
    var maxShown = 8

    private var manager: ClaudeSessionManager { appState.claudeSessions }

    /// Only the Claudes no session claims: a matched one is listed with
    /// its session instead (see docs/claude-matched-sessions-plan.md).
    private var unmatched: [ClaudeActivity] {
        appState.unmatchedClaudes(appState.claudeMatches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                    .monitorFont(size: 10, design: .default)
                    .foregroundColor(Color.onyxPurple)
                Text("CLAUDE SESSIONS")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(Color.onyxPurple)
                    .tracking(2)

                Spacer()

                Text("\(unmatched.count)")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.4))
            }

            // Permission requests (urgent, shown first)
            ForEach(manager.pendingPermissions) { request in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield")
                        .monitorFont(size: 12, design: .default)
                        .foregroundColor(Color.onyxAmber)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.toolName)")
                            .monitorFont(size: 11, weight: .medium)
                            .foregroundColor(.white.opacity(0.9))
                        Text(request.summary)
                            .monitorFont(size: 10)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { manager.approvePermission(request.id) }) {
                        Text("Allow")
                            .monitorFont(size: 10, weight: .medium)
                            .foregroundColor(Color.onyxGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.onyxGreen.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)

                    Button(action: { manager.denyPermission(request.id) }) {
                        Text("Deny")
                            .monitorFont(size: 10, weight: .medium)
                            .foregroundColor(Color.onyxRed)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.onyxRed.opacity(0.15))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.onyxAmber.opacity(0.06))
                .cornerRadius(6)
            }

            // Claudes no session claims
            let active = unmatched
            ForEach(Array(active.prefix(maxShown))) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionStatusColor(session.status))
                        .frame(width: 6, height: 6)

                    // Where it's running — the tmux session, else the
                    // machine. The session id is only a fallback, for a
                    // bridge too old to say.
                    Text(Self.place(session))
                        .monitorFont(size: 10)
                        .foregroundColor(Color.onyxPurple.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 110, alignment: .leading)
                        .help(session.origin.map { "\($0.label)\nClaude session \(session.id)" }
                              ?? "Claude session \(session.id)")

                    ClaudeStatusText(activity: session)

                    Spacer()

                    Text(relativeTime(session.lastSeen))
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                }
            }
            if active.count > maxShown {
                Text("+\(active.count - maxShown) more")
                    .monitorFont(size: 9)
                    .foregroundColor(.gray.opacity(0.4))
            }
        }
    }

    /// What to call a session's location in one short label.
    static func place(_ session: ClaudeActivity) -> String {
        if let origin = session.origin {
            return origin.session ?? origin.machine
        }
        return String(session.id.prefix(8))
    }

    private func sessionStatusColor(_ status: ClaudeActivity.ClaudeStatus) -> Color {
        switch status {
        case .running: return Color.onyxGreen
        case .waitingPermission: return Color.onyxAmber
        case .idle: return Color.onyxBlue.opacity(0.5)
        case .stopped: return .gray.opacity(0.3)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 5 { return "now" }
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
    }
}

/// What one Claude is doing, in a few words: the tool it's running (and
/// on what), "waiting for permission", or "idle".
struct ClaudeStatusText: View {
    let activity: ClaudeActivity
    /// Tint for the tool name — purple where it sits under a session, to
    /// say whose line this is.
    var toolColor: Color = .white.opacity(0.8)

    var body: some View {
        switch activity.status {
        case .running(let tool):
            Text(tool)
                .monitorFont(size: 11, weight: .medium)
                .foregroundColor(toolColor)
            if let input = activity.toolInput, !input.isEmpty {
                Text(input)
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .waitingPermission:
            Text("waiting for permission")
                .monitorFont(size: 11)
                .foregroundColor(Color.onyxAmber)
                .modifier(PulseModifier())
        case .idle:
            Text("idle")
                .monitorFont(size: 11)
                .foregroundColor(.gray.opacity(0.4))
        case .stopped:
            Text("waiting for you")
                .monitorFont(size: 11)
                .foregroundColor(.gray.opacity(0.45))
        }
    }
}

/// A matched session's second line: what its Claude is doing, in Claude's
/// purple. With several Claudes, the one that most needs you speaks and
/// the rest are a count.
struct ClaudeActivityLine: View {
    let claudes: [ClaudeActivity]

    var body: some View {
        if let lead = Self.lead(of: claudes) {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .monitorFont(size: 9, design: .default)
                    .foregroundColor(lead.status == .waitingPermission ? Color.onyxAmber : Color.onyxPurple)
                ClaudeStatusText(activity: lead, toolColor: Color.onyxPurple.opacity(0.9))
                if claudes.count > 1 {
                    Text("+\(claudes.count - 1)")
                        .monitorFont(size: 9)
                        .foregroundColor(Color.onyxPurple.opacity(0.6))
                        .help("\(claudes.count) Claudes in this session")
                }
            }
            .lineLimit(1)
            .help(lead.origin.map { "\($0.label)\nClaude session \(lead.id)" } ?? "Claude session \(lead.id)")
        }
    }

    /// The Claude to show: waiting for permission first, then running,
    /// then the most recently heard from.
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
}

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

struct SessionNotesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SessionNotesStore.shared
    /// Observed so each row's clock is current: the rows are built here.
    @ObservedObject private var activity = TerminalActivityStore.shared

    /// The shortcut number is the session's position in the FAVORITES bar,
    /// never its position in this list. A favorite with no row is skipped
    /// here but still owns its number — that mismatch (press ⌘4, land on
    /// the 5th favorite) is exactly what the badges exist to prevent.
    var body: some View {
        let entries = orderedSessionNotes(appState: appState, store: store)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SESSIONS")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    Text("⌘; to add a note")
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                }
                ForEach(entries, id: \.session.id) { entry in
                    SessionNoteRow(
                        entry: entry,
                        isActive: appState.activeSession?.id == entry.session.id,
                        accentColor: appState.accentColor,
                        alertKey: appState.storageKey(for: entry.session),
                        // jumpToSession, not switchToSession: it routes through
                        // the terminal pool (so the session's view actually
                        // activates) and drops the overlays covering it —
                        // clicking a row always means "take me there".
                        onTap: { appState.jumpToSession(entry.session,
                                                        dismissIfAlreadyActive: false)
                        }
                    )
                }
            }
        }
    }
}

private struct SessionNoteRow: View {
    let entry: SessionNoteEntry
    let isActive: Bool
    let accentColor: Color
    /// Storage key for this session, so alerts can be looked up.
    let alertKey: String?
    let onTap: () -> Void
    @Environment(\.monitorFontScale) private var fontScale

    private var session: TmuxSession { entry.session }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                // Selected marker: a full-height accent bar. The old 5pt dot
                // was easy to miss on a list of similar-looking rows.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? accentColor : Color.clear)
                    .frame(width: 3)
                // ⌘N badge, same number as the favorites bar. Reserve the
                // slot even for non-favorites so note text stays aligned.
                Text(entry.shortcut.map { "⌘\($0)" } ?? "")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(isActive ? accentColor : .gray.opacity(0.45))
                    .frame(width: 22 * fontScale, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .monitorFont(size: 12, weight: isActive ? .medium : .regular)
                        .foregroundColor(entry.note == nil
                                         ? (isActive ? accentColor : accentColor.opacity(0.85))
                                         : (isActive ? .white : .white.opacity(0.85)))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.claudes.isEmpty {
                        // Matched: the second line is what Claude is doing.
                        // The session's name moves into the first line when
                        // there's no note, and is a hover away when there is.
                        ClaudeActivityLine(claudes: entry.claudes)
                            .help(session.displayLabel)
                    } else if let note = entry.note {
                        HStack(spacing: 6) {
                            Text(session.displayLabel)
                                .monitorFont(size: 10)
                                .foregroundColor(isActive ? accentColor : accentColor.opacity(0.7))
                            Text(note.updated, style: .relative)
                                .monitorFont(size: 9)
                                .foregroundColor(.gray.opacity(0.4))
                        }
                    }
                }
                Spacer(minLength: 0)
                // Anything an agent said about this session. Sits next to
                // the note because the note is what tells you which piece
                // of work this row is.
                SessionAlertIndicator(sessionKey: alertKey, accentColor: accentColor,
                                      size: 11 * fontScale)
                // How long since this session last did anything — terminal
                // output, or a Claude's hook. Green when it just did, gray
                // "idle" once it's been quiet — so a test run that finished
                // (or hung) stands out from one still churning.
                activityIndicator
                    .padding(.top, 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? accentColor.opacity(0.5) : Color.clear,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())   // whole row is the tap target
        }
        .buttonStyle(.plain)
    }

    /// Time-since-last-activity chip. A TimelineView re-evaluates it every
    /// few seconds so the color drifts active → idle as a session goes
    /// quiet, even when nothing new is arriving.
    @ViewBuilder
    private var activityIndicator: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let last = entry.lastActivity {
                let idle = context.date.timeIntervalSince(last)
                let color = monitorSessionActivityColor(idle)
                // Deliberately larger than everything else in the overlay:
                // whether a session is still churning or has gone quiet is
                // the one thing worth reading across the room. Sizes scale
                // with the UI font like the rest of the monitor.
                HStack(spacing: 4) {
                    Image(systemName: monitorSessionActivityIcon(idle))
                        .monitorFont(size: 15, weight: .semibold, design: .default)
                    Text(last, style: .relative)
                        .monitorFont(size: 11, weight: .medium)
                        .lineLimit(1)
                }
                .foregroundColor(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.12))
                .cornerRadius(4)
                .help(idle < 15 ? "Active now"
                                : "Quiet for \(Int(idle))s — likely idle")
            }
        }
    }
}
