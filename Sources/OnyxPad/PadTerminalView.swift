//
// PadTerminalView.swift
//
// Responsibility: SwiftTerm's UIKit terminal view, showing a PadTerminal:
//                 screen bytes in, keystrokes out, the size reported back.
// Scope: View. iOS only — on the Mac (where the package also builds) it is
//        a placeholder, since the Mac's terminals are its own.
//
// Hardware keyboards: SwiftTerm handles the keys a terminal needs; what an
// iPad keyboard lacks is Esc, so ⌘. sends one (the Mac's "cancel" chord,
// and what other iPad terminals settled on). The on-screen keyboard gets
// SwiftTerm's accessory row with Esc, Ctrl, Tab and the arrows.
//

import SwiftUI
import OnyxCore

#if canImport(UIKit)
import UIKit
import SwiftTerm

struct PadTerminalView: UIViewRepresentable {
    @ObservedObject var terminal: PadTerminal
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(terminal: terminal) }

    func makeUIView(context: Context) -> EscapableTerminalView {
        let view: EscapableTerminalView
        if let kept = terminal.hostView as? EscapableTerminalView {
            view = kept
        } else {
            // A real size from the start: SwiftTerm sizes its buffer from
            // the frame, and tmux would draw for a zero-width terminal.
            view = EscapableTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
            view.nativeBackgroundColor = .black
            view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
            view.backgroundColor = .black
            view.optionAsMetaKey = true
            terminal.hostView = view
        }
        context.coordinator.bind(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    /// Exactly the space offered. SwiftTerm's view has an ideal size of its
    /// own, and SwiftUI would center that — overflowing a narrow column on
    /// both sides, so the start of every line was off screen.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EscapableTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }

    func updateUIView(_ view: EscapableTerminalView, context: Context) {
        if context.coordinator.terminal !== terminal {
            context.coordinator.terminal = terminal
            context.coordinator.bind(view)
        }
    }

    static func dismantleUIView(_ view: EscapableTerminalView, coordinator: Coordinator) {
        // The view stays with the terminal for the next time it's shown;
        // only the drawing link is cut.
        coordinator.terminal.output = nil
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var terminal: PadTerminal

        init(terminal: PadTerminal) { self.terminal = terminal }

        func bind(_ view: EscapableTerminalView) {
            view.terminalDelegate = self
            view.onEscape = { [weak self] in self?.terminal.send(Data([0x1B])) }
            terminal.output = { [weak view] data in
                view?.feed(byteArray: ArraySlice([UInt8](data)))
            }
            let size = view.getTerminal().getDims()
            terminal.resize(columns: size.cols, rows: size.rows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            terminal.send(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            terminal.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            terminal.title = title.isEmpty ? nil : title
        }

        func bell(source: TerminalView) {
            terminal.rang()
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") else { return }
            UIApplication.shared.open(url)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
    }
}

/// SwiftTerm's view, plus ⌘. for Esc.
final class EscapableTerminalView: TerminalView {
    var onEscape: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(title: "Esc", action: #selector(sendEscape), input: ".", modifierFlags: .command)
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }

    @objc private func sendEscape() { onEscape?() }
}

#else

/// The Mac builds this target for its tests; it never shows a terminal.
struct PadTerminalView: View {
    @ObservedObject var terminal: PadTerminal
    let fontSize: CGFloat

    var body: some View {
        Text("\(terminal.session.name) — the iPad's terminal")
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

#endif
