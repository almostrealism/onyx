//
// FocusedTextField.swift
//
// Responsibility: A single-line text field that takes the keyboard when
//                 it appears and KEEPS it — inside the app's overlay
//                 stack, where SwiftUI's TextField does neither reliably.
// Scope: Views. NSViewRepresentable over NSTextField.
//
// Two overlays now depend on this for the same reason, found twice:
//
// The note editor: SwiftUI's TextField + @FocusState is asynchronous, so
// a follow-up "select all" raced the focus landing and, when it lost,
// selected the terminal behind the overlay instead.
//
// The pipeline adder: after one submit (text cleared programmatically
// during onSubmit), SwiftUI's TextField stopped accepting paste and could
// not be refocused by clicking — its field editor was gone and nothing
// brought it back. Adding a second pipeline meant closing and reopening
// the panel. An NSTextField that we make first responder ourselves has
// neither problem: a submit runs the action and the field simply keeps
// the keyboard.
//

import SwiftUI
import AppKit

/// NSTextField-backed text field we can focus and select atomically on
/// appear. SwiftUI's TextField + @FocusState is async, so any
/// follow-up "select all" sent via the responder chain races against
/// the focus landing — when it loses the race the terminal behind the
/// overlay becomes the recipient and its contents get selected, which
/// is exactly the bug we hit before.
struct FocusedSelectAllField: NSViewRepresentable {
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
        @objc func submit(_ sender: Any?) {
            onSubmit()
            // Submitting is not leaving. A panel that stays open for the
            // next entry — the pipeline adder — wants the keyboard right
            // where it was; the action may have cleared the text, and
            // AppKit ends editing on Return, so put the field editor back
            // once the action has run.
            if let field = sender as? NSTextField, let window = field.window,
               window.firstResponder !== field.currentEditor() {
                DispatchQueue.main.async { window.makeFirstResponder(field) }
            }
        }
    }
}
