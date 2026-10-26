import SwiftUI
import AppKit
import OnyxCore
import OnyxUI

/// A file from the file browser, full-window and editable. ⌘S saves, Esc
/// closes (asking first if there are unsaved edits).
struct FileEditorOverlay: View {
    @ObservedObject var appState: AppState
    @ObservedObject var editor: FileEditorManager

    private var accent: Color { appState.accentColor }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(accent.opacity(0.3))
                if editor.confirmingDiscard { discardBanner }
                if editor.phase == .conflict { conflictBanner }
                if let error = editor.saveError { errorBanner(error) }
                content
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.system(size: 13))
                .foregroundColor(accent)
            Text(editor.fileName)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
            if editor.isDirty {
                Circle().fill(Color.onyxAmber).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Text("\(editor.path ?? "") · \(editor.hostLabel)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 12)

            Text(status)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.55))

            Button(action: { editor.save() }) {
                Text("Save ⌘S")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(canSave ? accent : .gray.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)

            Button(action: { appState.closeFileEditor() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(.gray.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var canSave: Bool { editor.phase == .editing && editor.isDirty }

    private var status: String {
        switch editor.phase {
        case .loading: return "Loading…"
        case .saving: return "Saving…"
        case .conflict: return "Not saved"
        case .refused: return ""
        case .editing:
            if editor.isDirty { return "Modified" }
            if let saved = editor.lastSaved {
                let f = DateFormatter()
                f.dateFormat = "H:mm:ss"
                return "Saved \(f.string(from: saved))"
            }
            return ""
        }
    }

    // MARK: Banners

    private var discardBanner: some View {
        banner(color: Color.onyxAmber,
               text: "You have unsaved changes.") {
            bannerButton("Discard them") { appState.closeFileEditor(force: true) }
            bannerButton("Keep editing") { editor.confirmingDiscard = false }
        }
    }

    private var conflictBanner: some View {
        banner(color: Color.onyxRed,
               text: "This file changed on \(editor.hostLabel) since you opened it, so it wasn't saved.") {
            bannerButton("Overwrite with mine") { editor.overwrite() }
            bannerButton("Reload theirs (lose mine)") { editor.reload() }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        banner(color: Color.onyxRed, text: message) { EmptyView() }
    }

    private func banner<Buttons: View>(color: Color, text: String,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 14) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
    }

    private func bannerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch editor.phase {
        case .loading:
            centered { ProgressView().scaleEffect(0.7).colorScheme(.dark) }
        case .refused(let reason):
            centered {
                Text(reason)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.7))
            }
        case .editing, .saving, .conflict:
            PlainTextEditor(text: $editor.text,
                            fontSize: max(11, appState.appearance.fontSize),
                            editable: editor.phase == .editing || editor.phase == .conflict)
        }
    }

    private func centered<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        VStack { Spacer(); v(); Spacer() }.frame(maxWidth: .infinity)
    }
}

/// An NSTextView for code: monospaced, no smart quotes or dashes, no
/// spelling fixes — every one of those silently changes a file's bytes.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.textColor = NSColor.white.withAlphaComponent(0.9)
        tv.insertionPointColor = .white
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 20, height: 16)
        tv.string = text
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = editable
        // Only when the text changed from outside (a reload) — writing it
        // back on every keystroke would reset the selection and undo.
        if tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
