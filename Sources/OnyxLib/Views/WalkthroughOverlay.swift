import SwiftUI

/// A short guided tour of what Onyx does, shown once on first launch and
/// reachable afterwards from Help → Onyx Walkthrough.
///
/// This exists because of what real users asked for. The requests weren't
/// for missing features — they were for features that already shipped
/// ("how do I switch between sessions with the keyboard"). The help
/// screen lists every key, but a list of keys answers "what does ⌘J do",
/// not "what can this thing do for me". So the tour is organised by the
/// job you're trying to do, names the keys as a consequence, and is
/// short enough to finish.
struct WalkthroughOverlay: View {
    @ObservedObject var appState: AppState
    @State private var page = 0

    private var accent: Color { appState.accentColor }

    // MARK: - Content

    private struct Step: Identifiable {
        let id = UUID()
        let title: String
        let body: String
        /// Keys shown as chips. The point of the tour is that these stop
        /// being trivia, so every step that has them shows them.
        let keys: [(String, String)]
    }

    private var steps: [Step] {
        [
            Step(title: "Everything is a keystroke away",
                 body: "Onyx sits over whatever you're doing. One key brings up the monitor — every machine, what's due today, which builds are red — and the same key puts it away. Nothing here needs the mouse.",
                 keys: [("`", "monitor overlay"), ("⌘K", "command palette"), ("⌘/", "every shortcut")]),

            Step(title: "Move between sessions without reaching for the mouse",
                 body: "Your terminals are tmux sessions that stay alive on the far end. New sessions get a number automatically — ⌘1 through ⌘9 — so you can jump straight to them without setting anything up. ⇧⇥ cycles through the rest in order, and the session list has everything else, including sessions you started outside Onyx.",
                 keys: [("⌘1–9", "jump to a favorite"), ("⇧⇥", "cycle sessions"), ("⌘J", "the session list")]),

            Step(title: "Sessions that remember what they were for",
                 body: "Come back to nine terminals and the hard part isn't reconnecting, it's remembering which was which. Give each one a note — \"waiting on the migration\", \"epoch 14/40\" — and the monitor lists them with a dot showing which are still producing output. Sessions can be renamed or ended too — right-click one anywhere it appears: the session list (⌘J) or the favorites bar along the bottom.",
                 keys: [("⌘;", "note this session"), ("⌘J", "the session list"),
                        ("right-click", "rename or end a session")]),

            Step(title: "Files, git and search on the far machine",
                 body: "Browse the remote filesystem with the branch, staged files and working changes right above the listing. Search by name or type across a deep tree. Favourite folders are drawn as a treemap, so two folders with the same name are told apart by what contains them.\n\nWhen the panel is open it takes the keyboard, so typing goes to it rather than the shell. ⌘⌥← sends the keyboard back to the terminal and ⌘⌥→ returns it to the panel; the panel says which way round it currently is.",
                 keys: [("⌘O", "file browser"), ("⌘⌥←", "keyboard to the terminal"),
                        ("⌘⌥→", "keyboard to the panel"), ("⌘Y", "preview a file")]),

            Step(title: "Drop a file to hand it to whatever you're running",
                 body: "Drag a file onto the terminal and its path is typed at the cursor — the gesture you already use to point Claude Code at a file. When the session is on another machine that path would be meaningless, so Onyx copies the file over first and inserts where it landed.",
                 keys: [("drag & drop", "onto the terminal")]),

            Step(title: "The work you're waiting on",
                 body: "Open pull requests from GitHub and GitLab arrive in one list, with unresolved review threads and whether each would actually merge. Pipelines sit above them. Apple Reminders due today show up alongside, because what's due is part of the same picture. Add your tokens in Settings.",
                 keys: [("`", "then look right"), ("⌘,", "settings")]),

            Step(title: "Watching more than one machine",
                 body: "The monitor starts on the host you're looking at. F widens it to every machine you have — one row each, sharing a time axis so a spike on one lines up with a spike on another — then to the whole fleet as a single pair of charts. S switches between the detailed view and one you can read across a room.",
                 keys: [("F", "this host → fleet"), ("S", "detailed / simple"), ("T", "time window")]),

            Step(title: "Working alongside agents",
                 body: "Claude Code sessions show up as sessions, so an agent that finished — or one that stopped to ask permission — is visible instead of buried in a tab. Agents can push a diagram or a model straight into the panel next to your terminal. Run 'Install Onyx MCP' from the command palette to wire it up — one step installs the bridge, registers it with Claude Code and configures the hooks. The monitor's CONNECTIONS section then shows whether it's working, per host.",
                 keys: [("⌘K", "→ Install Onyx MCP"), ("⌘D", "artifacts panel")]),

            Step(title: "That's the tour",
                 body: "⌘/ lists every shortcut whenever you want it, and Help → Onyx Walkthrough brings this back. Settings has the pieces worth setting once: hosts, tokens, reminder lists, and a pause switch for any machine you'd rather Onyx left alone.",
                 keys: [("⌘/", "all shortcuts"), ("⌘,", "settings")]),
        ]
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { finish() }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.06))

                let step = steps[min(page, steps.count - 1)]
                VStack(alignment: .leading, spacing: 14) {
                    Text(step.title)
                        .font(.system(size: appState.uiSize(20), weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))

                    Text(step.body)
                        .font(.system(size: appState.uiSize(13)))
                        .foregroundColor(.white.opacity(0.65))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    if !step.keys.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(step.keys, id: \.0) { key, meaning in
                                HStack(spacing: 10) {
                                    Text(key)
                                        .font(.system(size: appState.uiSize(11), weight: .medium, design: .monospaced))
                                        .foregroundColor(accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(accent.opacity(0.10))
                                        .cornerRadius(4)
                                    Text(meaning)
                                        .font(.system(size: appState.uiSize(11), design: .monospaced))
                                        .foregroundColor(.gray.opacity(0.6))
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)

                Divider().background(Color.white.opacity(0.06))
                footer
            }
            .frame(width: 560)
            .background(Color.black.opacity(0.92))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private var header: some View {
        HStack {
            Text("ONYX")
                .font(.system(size: appState.uiSize(11), weight: .medium, design: .monospaced))
                .foregroundColor(accent)
                .tracking(3)
            Spacer()
            Text("\(page + 1) / \(steps.count)")
                .font(.system(size: appState.uiSize(10), design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Skip stays available on every page. A tour you can't leave
            // is an ad.
            Button(action: finish) {
                Text(page == steps.count - 1 ? "Done" : "Skip")
                    .font(.system(size: appState.uiSize(11), design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
            .buttonStyle(.plain)

            Spacer()

            if page > 0 {
                Button(action: { page -= 1 }) {
                    Text("← Back")
                        .font(.system(size: appState.uiSize(11), design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            Button(action: advance) {
                Text(page == steps.count - 1 ? "Start using Onyx" : "Next →")
                    .font(.system(size: appState.uiSize(11), weight: .medium, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(accent)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func advance() {
        if page == steps.count - 1 { finish() } else { page += 1 }
    }

    /// Closing by any route — Done, Skip, Escape, a click outside — counts
    /// as seen. Re-showing a tour someone dismissed is how you teach them
    /// to dismiss things without reading.
    private func finish() {
        appState.showWalkthrough = false
        if !appState.appearance.hasSeenWalkthrough {
            appState.appearance.hasSeenWalkthrough = true
            appState.saveAppearance()
        }
    }
}
