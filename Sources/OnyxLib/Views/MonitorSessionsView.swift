import SwiftUI


struct ClaudeSessionsSection: View {
    @ObservedObject var appState: AppState

    private var manager: ClaudeSessionManager { appState.claudeSessions }

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

                Text("\(manager.activeSessions.count)")
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

            // Active sessions
            ForEach(manager.activeSessions) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(sessionStatusColor(session.status))
                        .frame(width: 6, height: 6)

                    Text(shortSessionId(session.id))
                        .monitorFont(size: 10)
                        .foregroundColor(Color.onyxPurple.opacity(0.7))
                        .frame(width: 50, alignment: .leading)

                    switch session.status {
                    case .running(let tool):
                        Text(tool)
                            .monitorFont(size: 11, weight: .medium)
                            .foregroundColor(.white.opacity(0.8))
                        if let input = session.toolInput, !input.isEmpty {
                            Text(input)
                                .monitorFont(size: 10)
                                .foregroundColor(.gray.opacity(0.5))
                                .lineLimit(1)
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
                        Text("stopped")
                            .monitorFont(size: 11)
                            .foregroundColor(.gray.opacity(0.3))
                    }

                    Spacer()

                    Text(relativeTime(session.lastSeen))
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                }
            }
        }
    }

    private func sessionStatusColor(_ status: ClaudeActivity.ClaudeStatus) -> Color {
        switch status {
        case .running: return Color.onyxGreen
        case .waitingPermission: return Color.onyxAmber
        case .idle: return Color.onyxBlue.opacity(0.5)
        case .stopped: return .gray.opacity(0.3)
        }
    }

    private func shortSessionId(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 5 { return "now" }
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
    }
}

/// Lists the user-supplied status notes attached to currently-existing
/// sessions, ordered like the favorites bar. Hides itself entirely when
/// there are no notes so the monitor doesn't carry a dead heading.
struct SessionNotesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SessionNotesStore.shared

    /// One rendered row: the note plus the ⌘N that actually reaches it.
    private struct Entry {
        let session: TmuxSession
        let note: SessionNote
        /// Favorites-bar position (1-based) — nil when this session isn't a
        /// favorite of this window and therefore has no ⌘N shortcut.
        let shortcut: Int?
    }

    /// Ordered to match the favorites bar at the bottom of the window:
    /// this window's favorites first in bar order, then any other noted
    /// session by most recent terminal output.
    ///
    /// The shortcut number is the session's position in the FAVORITES bar,
    /// never its position in this list. A favorite with no note is skipped
    /// here but still owns its number — that mismatch (press ⌘4, land on
    /// the 5th favorite) is exactly what the badges exist to prevent.
    private var orderedEntries: [Entry] {
        let noted = store.activeNotes(in: appState.allSessions)
        let byID = Dictionary(noted.map { ($0.session.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var rows: [Entry] = []
        var placed = Set<String>()
        for (idx, fav) in appState.favoriteSessions.enumerated() {
            guard let hit = byID[fav.id] else { continue }
            rows.append(Entry(session: hit.session,
                              note: hit.note,
                              shortcut: idx < 9 ? idx + 1 : nil))
            placed.insert(fav.id)
        }
        let rest = noted
            .filter { !placed.contains($0.session.id) }
            .sorted { lastActivity($0) > lastActivity($1) }
        rows.append(contentsOf: rest.map {
            Entry(session: $0.session, note: $0.note, shortcut: nil)
        })
        return rows
    }

    /// Most recent terminal output, falling back to when the note itself was
    /// touched for a session that hasn't printed anything yet.
    private func lastActivity(_ entry: (session: TmuxSession, note: SessionNote)) -> Date {
        TerminalActivityStore.shared.lastOutput(for: entry.session.id) ?? entry.note.updated
    }

    var body: some View {
        let entries = orderedEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SESSION NOTES")
                        .monitorFont(size: 10, weight: .medium)
                        .foregroundColor(appState.accentColor)
                        .tracking(2)
                    Spacer()
                    Text("⌘; to add")
                        .monitorFont(size: 9)
                        .foregroundColor(.gray.opacity(0.3))
                }
                ForEach(entries, id: \.session.id) { entry in
                    SessionNoteRow(
                        session: entry.session,
                        note: entry.note,
                        shortcut: entry.shortcut,
                        isActive: appState.activeSession?.id == entry.session.id,
                        accentColor: appState.accentColor,
                        // jumpToSession, not switchToSession: it routes through
                        // the terminal pool (so the session's view actually
                        // activates) and drops the overlays covering it —
                        // clicking a note always means "take me there".
                        onTap: { appState.jumpToSession(entry.session,
                                                        dismissIfAlreadyActive: false) }
                    )
                }
            }
        }
    }
}

private struct SessionNoteRow: View {
    let session: TmuxSession
    let note: SessionNote
    /// Favorites-bar position, when this session has a ⌘N shortcut.
    let shortcut: Int?
    let isActive: Bool
    let accentColor: Color
    let onTap: () -> Void
    @Environment(\.monitorFontScale) private var fontScale

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
                Text(shortcut.map { "⌘\($0)" } ?? "")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(isActive ? accentColor : .gray.opacity(0.45))
                    .frame(width: 22 * fontScale, alignment: .leading)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.text)
                        .monitorFont(size: 12, weight: isActive ? .medium : .regular)
                        .foregroundColor(isActive ? .white : .white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(session.displayLabel)
                            .monitorFont(size: 10)
                            .foregroundColor(isActive ? accentColor : accentColor.opacity(0.7))
                        Text(note.updated, style: .relative)
                            .monitorFont(size: 9)
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
                // Terminal-output activity: how long since this session last
                // produced output. Green when it just printed something, grey
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

    /// Time-since-last-output chip. A TimelineView re-evaluates it every few
    /// seconds so the colour drifts active → idle as a session goes quiet,
    /// even when no new output (hence no store update) is arriving.
    @ViewBuilder
    private var activityIndicator: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let last = TerminalActivityStore.shared.lastOutput(for: session.id) {
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
                .help(idle < 15 ? "Producing output now"
                                : "Quiet for \(Int(idle))s — likely idle")
            }
        }
    }
}

