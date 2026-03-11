import SwiftUI

struct SessionManagerView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("SESSIONS")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(appState.accentColor)
                        .tracking(2)

                    Spacer()

                    Button(action: { appState.reconnectRequested = true }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Button(action: { appState.showSessionManager = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().background(Color.white.opacity(0.1))

                // Session groups
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.groupedSessions) { group in
                            SessionGroupHeader(group: group, appState: appState)

                            ForEach(group.sessions, id: \.id) { session in
                                SessionRow(session: session, appState: appState)
                            }
                        }

                        if appState.allSessions.isEmpty {
                            Text("No sessions found")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                                .padding(14)
                        }
                    }
                }

                Divider().background(Color.white.opacity(0.1))

                // Footer
                HStack {
                    // New host session button
                    Button(action: { appState.createNewSession = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 9))
                            Text("New Session")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundColor(.gray.opacity(0.5))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("⌘J close")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.25))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(width: 260)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.95)))

            // Thin accent border on the right edge
            Rectangle()
                .fill(appState.accentColor.opacity(0.2))
                .frame(width: 1)

            Spacer()
        }
    }
}

private struct SessionGroupHeader: View {
    let group: SessionGroup
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundColor(appState.accentColor.opacity(0.5))

            Text(group.source.displayName.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)

            Spacer()

            let available = group.sessions.filter { !$0.unavailable }.count
            if available > 0 {
                Text("\(available)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var iconName: String {
        switch group.source {
        case .host: return "desktopcomputer"
        case .docker: return "shippingbox"
        }
    }
}

private struct SessionRow: View {
    let session: TmuxSession
    @ObservedObject var appState: AppState

    private var isActive: Bool {
        appState.activeSession?.id == session.id
    }

    private var isFavorited: Bool {
        appState.isFavorited(session)
    }

    var body: some View {
        HStack(spacing: 6) {
            if session.unavailable {
                // Unavailable placeholder — tmux not installed in container
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "FF6B6B").opacity(0.6))

                Text(session.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.35))
                    .italic()
                    .lineLimit(1)

                Spacer()
            } else {
                // Active indicator
                Circle()
                    .fill(isActive ? appState.accentColor : Color.clear)
                    .frame(width: 4, height: 4)

                Text(session.name)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular, design: .monospaced))
                    .foregroundColor(isActive ? appState.accentColor : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()

                // Favorite toggle
                Button(action: { appState.toggleFavorite(session) }) {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(isFavorited ? Color(hex: "FFD06B") : .gray.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isActive ? appState.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if !session.unavailable && !isActive {
                appState.switchToSession = session
            }
        }
    }
}
