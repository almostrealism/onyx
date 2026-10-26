//
// Palette+AppKit.swift
//
// Responsibility: The AppKit half of the Onyx palette (`Color(hex:)` and
//                 the status colors are in OnyxCore's Palette.swift).
// Scope: Mac only.
//

import AppKit
import OnyxCore

extension NSColor {
    /// AppKit counterpart of `Color(hex:)` for the few SceneKit / layer
    /// surfaces that need an NSColor. Returns nil on a malformed hex.
    convenience init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard h.count == 6, let int = UInt64(h, radix: 16) else { return nil }
        self.init(
            red: CGFloat((int >> 16) & 0xFF) / 255.0,
            green: CGFloat((int >> 8) & 0xFF) / 255.0,
            blue: CGFloat(int & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
