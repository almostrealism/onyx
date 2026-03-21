import SwiftUI

struct SessionManagerView: View {
    @ObservedObject var appState: AppState
    @State private var newSessionName = ""
    @State private var newSessionHostID: UUID?
    @State private var newSessionSource: SessionSource?
    @FocusState private var nameFieldFocused: Bool

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("SESSIONS")
                        .font(.system(size: sz(11), weight: .medium, design: .monospaced))
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

                // Session list
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Favorites section (reorderable)
                        if !appState.favoriteSessions.isEmpty {
                            FavoritesHeader(count: appState.favoriteSessions.count, appState: appState)

                            ForEach(Array(appState.favoriteSessions.enumerated()), id: \.element.id) { index, session in
                                FavoriteRow(session: session, index: index, total: appState.favoriteSessions.count, appState: appState)
                            }

                            Divider()
                                .background(Color.white.opacity(0.06))
                                .padding(.vertical, 4)
                        }

                        // All sessions grouped by host
                        ForEach(appState.hostGroupedSessions) { hostGroup in
                            HostHeader(hostGroup: hostGroup, appState: appState)

                            ForEach(hostGroup.groups) { group in
                                if group.source.isDocker {
                                    SessionGroupHeader(group: group, appState: appState)
                                }

                                ForEach(group.sessions, id: \.id) { session in
                                    SessionRow(session: session, appState: appState)
                                        .id("row-\(session.id)")
                                }
                            }

                            if hostGroup.groups.isEmpty {
                                if appState.isEnumeratingSessions {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.5)
                                            .colorScheme(.dark)
                                        Text("Loading sessions...")
                                            .font(.system(size: sz(11), design: .monospaced))
                                            .foregroundColor(.gray.opacity(0.3))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                                } else {
                                    Text("No sessions")
                                        .font(.system(size: sz(11), design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.3))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 4)
                                }
                            }
                        }

                        if appState.allSessions.isEmpty && !appState.isEnumeratingSessions {
                            Text("No sessions found")
                                .font(.system(size: sz(12), design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                                .padding(14)
                        }
                    }
                }

                Divider().background(Color.white.opacity(0.1))

                // Footer
                if appState.showNewSessionPrompt {
                    NewSessionPrompt(
                        appState: appState,
                        newSessionName: $newSessionName,
                        newSessionHostID: $newSessionHostID,
                        newSessionSource: $newSessionSource,
                        nameFieldFocused: $nameFieldFocused,
                        onSubmit: submitNewSession,
                        onCancel: cancelNewSession
                    )
                } else {
                    HStack {
                        Button(action: { appState.showNewSessionPrompt = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: sz(9)))
                                Text("New Session")
                                    .font(.system(size: sz(10), design: .monospaced))
                            }
                            .foregroundColor(.gray.opacity(0.5))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text("⌘J close")
                            .font(.system(size: sz(9), design: .monospaced))
                            .foregroundColor(.gray.opacity(0.25))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
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

    private func submitNewSession() {
        let name = newSessionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let source = newSessionSource ?? .host(hostID: appState.hosts.first?.id ?? HostConfig.localhostID)
        appState.createNewSession = TmuxSession(name: name, source: source)
        appState.showNewSessionPrompt = false
        newSessionName = ""
    }

    private func cancelNewSession() {
        appState.showNewSessionPrompt = false
        newSessionName = ""
    }
}

// MARK: - New Session Prompt

private struct NewSessionPrompt: View {
    @ObservedObject var appState: AppState
    @Binding var newSessionName: String
    @Binding var newSessionHostID: UUID?
    @Binding var newSessionSource: SessionSource?
    var nameFieldFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    private var effectiveHostID: UUID {
        newSessionHostID ?? appState.hosts.first?.id ?? HostConfig.localhostID
    }

    var body: some View {
        VStack(spacing: 6) {
            // Host picker
            if appState.hosts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(appState.hosts) { host in
                            SourceButton(
                                label: host.label,
                                icon: host.isLocal ? "desktopcomputer" : "network",
                                selected: effectiveHostID == host.id,
                                accentColor: appState.accentColor
                            ) {
                                newSessionHostID = host.id
                                newSessionSource = .host(hostID: host.id)
                            }
                        }
                    }
                }
            }

            // Source picker (host vs docker containers on selected host)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    SourceButton(label: "Host", icon: "desktopcomputer",
                                 selected: !(newSessionSource?.isDocker ?? false),
                                 accentColor: appState.accentColor) {
                        newSessionSource = .host(hostID: effectiveHostID)
                    }

                    ForEach(appState.dockerContainerNames(forHost: effectiveHostID), id: \.self) { container in
                        let source = SessionSource.docker(hostID: effectiveHostID, containerName: container)
                        SourceButton(label: container, icon: "shippingbox",
                                     selected: newSessionSource == source, accentColor: appState.accentColor) {
                            newSessionSource = source
                        }
                    }
                }
            }

            // Name + actions
            HStack(spacing: 6) {
                TextField("Session name", text: $newSessionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: sz(11), design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                    .focused(nameFieldFocused)
                    .onSubmit { onSubmit() }

                Button(action: { onSubmit() }) {
                    Image(systemName: "return")
                        .font(.system(size: sz(10)))
                        .foregroundColor(appState.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button(action: { onCancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: sz(10)))
                        .foregroundColor(.gray.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onAppear {
            newSessionName = ""
            newSessionHostID = appState.activeHost?.id
            if let hostID = newSessionHostID {
                newSessionSource = .host(hostID: hostID)
            }
            nameFieldFocused.wrappedValue = true
        }
    }
}

// MARK: - Host Header

private struct HostHeader: View {
    let hostGroup: HostGroup
    @ObservedObject var appState: AppState

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hostGroup.host.isLocal ? "desktopcomputer" : "network")
                .font(.system(size: sz(9)))
                .foregroundColor(appState.accentColor.opacity(0.6))

            Text(hostGroup.host.label.uppercased())
                .font(.system(size: sz(9), weight: .bold, design: .monospaced))
                .foregroundColor(appState.accentColor.opacity(0.7))
                .tracking(1)

            Spacer()

            let available = hostGroup.groups.flatMap(\.sessions).filter { !$0.unavailable }.count
            if available > 0 {
                Text("\(available)")
                    .font(.system(size: sz(9), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

private struct FavoritesHeader: View {
    let count: Int
    @ObservedObject var appState: AppState

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: sz(9)))
                .foregroundColor(Color(hex: "FFD06B").opacity(0.6))

            Text("FAVORITES")
                .font(.system(size: sz(9), weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .tracking(1)

            Spacer()

            Text("\(count)")
                .font(.system(size: sz(9), design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct FavoriteRow: View {
    let session: TmuxSession
    let index: Int
    let total: Int
    @ObservedObject var appState: AppState

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    private var isActive: Bool {
        appState.activeSession?.id == session.id
    }

    var body: some View {
        HStack(spacing: 5) {
            // Move up/down
            VStack(spacing: 0) {
                Button(action: {
                    appState.moveFavoriteByID(session.id, direction: -1)
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: sz(7), weight: .bold))
                        .foregroundColor(index > 0 ? .gray.opacity(0.4) : .gray.opacity(0.1))
                        .frame(width: 16, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button(action: {
                    appState.moveFavoriteByID(session.id, direction: 1)
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: sz(7), weight: .bold))
                        .foregroundColor(index < total - 1 ? .gray.opacity(0.4) : .gray.opacity(0.1))
                        .frame(width: 16, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index >= total - 1)
            }

            // Tappable session label area
            HStack(spacing: 5) {
                // Position number
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: sz(8), design: .monospaced))
                        .foregroundColor(.gray.opacity(0.3))
                        .frame(width: 10)
                }

                Circle()
                    .fill(isActive ? appState.accentColor : Color.clear)
                    .frame(width: 4, height: 4)

                Text(session.displayLabel)
                    .font(.system(size: sz(11), weight: isActive ? .medium : .regular, design: .monospaced))
                    .foregroundColor(isActive ? appState.accentColor : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isActive {
                    appState.switchToSession = session
                }
            }

            // Remove from favorites
            Button(action: { appState.toggleFavorite(session) }) {
                Image(systemName: "star.slash")
                    .font(.system(size: sz(9)))
                    .foregroundColor(.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isActive ? appState.accentColor.opacity(0.08) : Color.clear)
    }
}

private struct SourceButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(selected ? .white : .gray.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? accentColor.opacity(0.3) : Color.white.opacity(0.06))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

private struct SessionGroupHeader: View {
    let group: SessionGroup
    @ObservedObject var appState: AppState

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.system(size: sz(8)))
                .foregroundColor(appState.accentColor.opacity(0.4))

            Text(group.source.displayName.uppercased())
                .font(.system(size: sz(8), weight: .medium, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
                .tracking(1)

            Spacer()

            let available = group.sessions.filter { !$0.unavailable }.count
            if available > 0 {
                Text("\(available)")
                    .font(.system(size: sz(8), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct SessionRow: View {
    let session: TmuxSession
    @ObservedObject var appState: AppState

    private func sz(_ base: CGFloat) -> CGFloat { appState.uiSize(base) }

    private var isActive: Bool {
        appState.activeSession?.id == session.id
    }

    private var isFavorited: Bool {
        appState.isFavoriteInWindow(session, windowIndex: appState.windowIndex)
    }

    private var isFavoritedAnyWindow: Bool {
        appState.isFavorited(session)
    }

    private var isUtility: Bool {
        session.source.isUtility
    }

    private var utilityIcon: String {
        if session.source.isDockerTop { return "list.number" }
        return "doc.text"
    }

    private var utilityLabel: String {
        if session.source.isDockerTop { return "processes" }
        return "logs"
    }

    var body: some View {
        HStack(spacing: 6) {
            if session.unavailable {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: sz(9)))
                    .foregroundColor(Color(hex: "FF6B6B").opacity(0.6))

                Text(session.name)
                    .font(.system(size: sz(11), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.35))
                    .italic()
                    .lineLimit(1)

                Spacer()
            } else if isUtility {
                Image(systemName: utilityIcon)
                    .font(.system(size: sz(9)))
                    .foregroundColor(isActive ? appState.accentColor.opacity(0.7) : .gray.opacity(0.4))

                Text(utilityLabel)
                    .font(.system(size: sz(11), weight: isActive ? .medium : .regular, design: .monospaced))
                    .foregroundColor(isActive ? appState.accentColor : .gray.opacity(0.5))
                    .italic()
                    .lineLimit(1)

                Spacer()

                Button(action: { appState.toggleFavorite(session) }) {
                    Image(systemName: isFavorited ? "star.fill" : (isFavoritedAnyWindow ? "star.leadinghalf.filled" : "star"))
                        .font(.system(size: sz(10)))
                        .foregroundColor(isFavorited ? Color(hex: "FFD06B") : (isFavoritedAnyWindow ? Color(hex: "FFD06B").opacity(0.4) : .gray.opacity(0.3)))
                }
                .buttonStyle(.plain)
            } else {
                Circle()
                    .fill(isActive ? appState.accentColor : Color.clear)
                    .frame(width: 4, height: 4)

                Text(session.name)
                    .font(.system(size: sz(12), weight: isActive ? .medium : .regular, design: .monospaced))
                    .foregroundColor(isActive ? appState.accentColor : .white.opacity(0.7))
                    .lineLimit(1)

                Spacer()

                Button(action: { appState.toggleFavorite(session) }) {
                    Image(systemName: isFavorited ? "star.fill" : (isFavoritedAnyWindow ? "star.leadinghalf.filled" : "star"))
                        .font(.system(size: sz(10)))
                        .foregroundColor(isFavorited ? Color(hex: "FFD06B") : (isFavoritedAnyWindow ? Color(hex: "FFD06B").opacity(0.4) : .gray.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if isFavorited {
                        ForEach(0..<4, id: \.self) { idx in
                            Button(action: { appState.toggleFavoriteWindow(session, windowIndex: idx) }) {
                                let isOn = appState.isFavoriteInWindow(session, windowIndex: idx)
                                Label("Window \(idx + 1)", systemImage: isOn ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
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
