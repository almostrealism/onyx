import SwiftUI
import AppKit

/// NSTextField-backed text field we can focus and select atomically on
/// appear. SwiftUI's TextField + @FocusState is async, so any
/// follow-up "select all" sent via the responder chain races against
/// the focus landing — when it loses the race the terminal behind the
/// overlay becomes the recipient and its contents get selected, which
/// is exactly the bug we hit before.
private struct FocusedSelectAllField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.placeholderString = placeholder
        field.stringValue = text
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        // Atomic focus + select. Runs after the view is in the window
        // so makeFirstResponder finds a window to work with. Selecting
        // before yielding back to the run loop prevents any other
        // responder from receiving a stray selectAll.
        DispatchQueue.main.async {
            if let window = field.window {
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() as? NSTextView {
                    editor.selectAll(nil)
                }
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Belt-and-suspenders on top of the app-wide disable: turn off smart
        // substitution directly on this field's editor so a typed " never
        // curls. (The field editor only exists while editing.)
        if let editor = nsView.currentEditor() as? NSTextView {
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void
        let onCancel: () -> Void
        init(text: Binding<String>, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text; self.onSubmit = onSubmit; self.onCancel = onCancel
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                // Strip any stylized punctuation (e.g. pasted curly quotes)
                // before it reaches the binding, rewriting the field in place.
                let clean = TextSanitizer.sanitize(field.stringValue)
                if clean != field.stringValue { field.stringValue = clean }
                text.wrappedValue = clean
            }
        }
        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // Escape cancels — handle it here rather than relying on
            // SwiftUI keyboardShortcut so the editor closes even with
            // focus inside the field.
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel(); return true
            }
            return false
        }
        @objc func submit(_ sender: Any?) { onSubmit() }
    }
}

/// Small text-field overlay for setting the status note on the currently
/// active tmux session. Triggered by Cmd+; — the user types a one-liner
/// like "waiting on test result for fine-tuning" and the note appears in
/// the monitor view between the timing chart and the reminders list.
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
               let existing = SessionNotesStore.shared.note(for: session.id) {
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
        SessionNotesStore.shared.setNote(text, for: session.id)
        appState.showSessionNoteEditor = false
    }
}
