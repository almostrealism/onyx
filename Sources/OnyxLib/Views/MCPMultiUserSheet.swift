import SwiftUI
import AppKit

/// Shown once after a successful MCP install, explaining what the other
/// accounts on that machine need to do.
///
/// Registration is per-user by construction: `claude mcp add --scope
/// user` writes the running user's `~/.claude.json`, so there is no way
/// to register the bridge for everyone from here. The best we can do is
/// hand the next person one command instead of a paragraph.
///
/// When the bridge landed in a home directory rather than /Users/Shared,
/// there is no command to give — another account can't read the file at
/// all — so the sheet says that plainly and says what would change it.
struct MCPMultiUserSheet: View {
    let hint: MultiUserHint
    @ObservedObject var appState: AppState
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ONYX MCP INSTALLED")
                        .monitorFont(size: 11, weight: .medium)
                        .foregroundColor(Color.onyxGreen)
                        .tracking(2)
                    Spacer()
                    Text(hint.host)
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.5))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.06))

                VStack(alignment: .leading, spacing: 12) {
                    if hint.isShared {
                        Text("Other accounts on this machine can use it too")
                            .font(.system(size: appState.uiSize(15), weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))

                        Text("The bridge is installed where every account can run it, but Claude Code registers MCP servers per user. Anyone else on this machine runs this once, as themselves:")
                            .font(.system(size: appState.uiSize(12)))
                            .foregroundColor(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text(hint.command)
                                .font(.system(size: appState.uiSize(11), design: .monospaced))
                                .foregroundColor(Color.onyxBlue)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5)

                            Button(action: copy) {
                                Text(copied ? "copied" : "copy")
                                    .monitorFont(size: 10)
                                    .foregroundColor(copied ? Color.onyxGreen
                                                            : Color.onyxBlue.opacity(0.8))
                                    .frame(width: 44)
                            }
                            .buttonStyle(.plain)
                        }

                        Text("It registers the same shared binary for that account and reports whether Claude picked it up.")
                            .font(.system(size: appState.uiSize(10)))
                            .foregroundColor(.gray.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Installed for this account only")
                            .font(.system(size: appState.uiSize(15), weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))

                        // Be specific about why, and about what would
                        // change it — "multi-user isn't supported" would
                        // be both vaguer and less true.
                        Text("The bridge went into this user's home directory, which the machine's other accounts can't read. For a machine with several users it needs to live in /Users/Shared instead.")
                            .font(.system(size: appState.uiSize(12)))
                            .foregroundColor(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Onyx uses /Users/Shared automatically when it exists and your user can write to it. If that's not the case here, create it or make it writable and install again — everything else about the install stays the same.")
                            .font(.system(size: appState.uiSize(11)))
                            .foregroundColor(.gray.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)

                Divider().background(Color.white.opacity(0.06))

                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Text("Done")
                            .font(.system(size: appState.uiSize(11), weight: .medium,
                                          design: .monospaced))
                            .foregroundColor(.black.opacity(0.85))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(appState.accentColor)
                            .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(width: 520)
            .background(Color.black.opacity(0.94))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint.command, forType: .string)
        copied = true
    }
}
