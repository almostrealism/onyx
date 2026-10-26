//
// TerminalKeyTranslation.swift
//
// Responsibility: The few keys Onyx sends to the terminal as something
//                 other than what SwiftTerm would send by itself.
// Scope: Service. Pure: a key and its modifiers in, bytes out.
//
// SwiftTerm sends Shift-Return as a plain carriage return, so programs
// can't tell it from Return. Claude Code (and other line editors) treat
// Shift-Return as "new line, don't submit" — and the byte sequence they
// recognize for it, in any terminal, is ESC CR: Meta-Return. It is what
// Claude Code's own /terminal-setup binds Shift-Return to in terminals
// that don't send it natively, and it survives tmux, which passes
// Meta-Return through as ESC CR. In a zsh prompt ESC CR inserts a line
// break into the command being edited, which is the same idea.
//

import AppKit
import OnyxCore

public enum TerminalKeyTranslation {

    /// Return on the main keyboard, and Enter on the keypad.
    static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// What to send instead of SwiftTerm's own bytes for this key, or nil
    /// to let SwiftTerm handle it.
    public static func bytes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        let flags = modifiers.intersection([.shift, .control, .option, .command])
        if flags == .shift && returnKeyCodes.contains(keyCode) {
            return [0x1b, 0x0d]   // ESC CR — "insert a newline"
        }
        return nil
    }
}
