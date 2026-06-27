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
/// sessions, sorted by recency. Hides itself entirely when there are
/// no notes so the monitor doesn't carry a dead heading.
struct SessionNotesSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var store = SessionNotesStore.shared

    var body: some View {
        let entries = store.activeNotes(in: appState.allSessions)
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
                        isActive: appState.activeSession?.id == entry.session.id,
                        accentColor: appState.accentColor,
                        // Route through switchToSession (like the favorites
                        // bar) so the terminal pool actually activates this
                        // session's view — setting activeSession alone only
                        // moved the indicator while the old terminal stayed up.
                        onTap: { appState.switchToSession = entry.session }
                    )
                }
            }
        }
    }
}

private struct SessionNoteRow: View {
    let session: TmuxSession
    let note: SessionNote
    let isActive: Bool
    let accentColor: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(isActive ? accentColor : Color.gray.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.text)
                        .monitorFont(size: 12)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(session.displayLabel)
                            .monitorFont(size: 10)
                            .foregroundColor(accentColor.opacity(0.7))
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
            .background(isActive ? Color.white.opacity(0.04) : Color.clear)
            .cornerRadius(3)
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
                HStack(spacing: 3) {
                    Image(systemName: monitorSessionActivityIcon(idle))
                        .font(.system(size: 8))
                    Text(last, style: .relative)
                        .monitorFont(size: 9)
                }
                .foregroundColor(monitorSessionActivityColor(idle))
                .help(idle < 15 ? "Producing output now"
                                : "Quiet for \(Int(idle))s — likely idle")
            }
        }
    }
}

