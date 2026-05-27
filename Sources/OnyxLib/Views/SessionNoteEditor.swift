import SwiftUI

/// Small text-field overlay for setting the status note on the currently
/// active tmux session. Triggered by Cmd+; — the user types a one-liner
/// like "waiting on test result for fine-tuning" and the note appears in
/// the monitor view between the timing chart and the reminders list.
struct SessionNoteEditor: View {
    @ObservedObject var appState: AppState
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { appState.showSessionNoteEditor = false }

            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("SESSION NOTE")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(appState.accentColor)
                        .tracking(3)
                    if let session = appState.activeSession {
                        Text(session.displayLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                }

                TextField("What's this session doing?", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .light, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($isFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(appState.accentColor.opacity(0.3), lineWidth: 1)
                    )
                    .onSubmit { save() }

                Text("Empty to clear · Esc to cancel · ⏎ to save")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.4))

                HStack(spacing: 12) {
                    Button(action: { appState.showSessionNoteEditor = false }) {
                        Text("Cancel")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: save) {
                        Text("Save")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(appState.accentColor)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(30)
            .frame(width: 460)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .onAppear {
            // Pre-populate with the current note text if any, so the
            // user can edit rather than start fresh.
            if let session = appState.activeSession,
               let existing = SessionNotesStore.shared.note(for: session.id) {
                text = existing.text
            }
            isFocused = true
        }
    }

    private func save() {
        guard let session = appState.activeSession else {
            appState.showSessionNoteEditor = false
            return
        }
        SessionNotesStore.shared.setNote(text, for: session.id)
        appState.showSessionNoteEditor = false
    }
}
