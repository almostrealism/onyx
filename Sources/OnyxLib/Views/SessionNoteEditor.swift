import SwiftUI
import AppKit

struct SessionNoteEditor: View {
    @ObservedObject var appState: AppState
    @State private var text: String

    init(appState: AppState) {
        self.appState = appState
        // Seed text BEFORE the field's makeNSView runs so the initial
        // stringValue + selection are both correct. Doing this in
        // .onAppear is too late — by then the NSTextField is already
        // built and `selectAll` would select an empty string.
        let seed: String = {
            if let session = appState.activeSession,
               let existing = appState.note(for: session) {
                return existing.text
            }
            return ""
        }()
        _text = State(initialValue: seed)
    }

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

                FocusedSelectAllField(
                    text: $text,
                    placeholder: "What's this session doing?",
                    font: NSFont.monospacedSystemFont(ofSize: 16, weight: .light),
                    textColor: .white,
                    onSubmit: { save() },
                    onCancel: { appState.showSessionNoteEditor = false }
                )
                .frame(height: 22)
                .padding(12)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(appState.accentColor.opacity(0.3), lineWidth: 1)
                )

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
    }

    private func save() {
        guard let session = appState.activeSession else {
            appState.showSessionNoteEditor = false
            return
        }
        appState.setNote(text, for: session)
        appState.showSessionNoteEditor = false
    }
}
