import SwiftUI
import AppKit

// MARK: - Hex parsing

public extension Color {
    /// Parse a 6-digit hex string ("66CCFF", "#66CCFF") into a Color.
    /// Non-hex characters are stripped; anything that isn't exactly six hex
    /// digits falls back to white so a bad value is visible rather than crashy.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 1; g = 1; b = 1
        }
        self.init(red: r, green: g, blue: b)
    }
}

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

// MARK: - Brand / status palette

public extension Color {
    /// The recurring Onyx status palette. These five colors were hardcoded
    /// as `Color(hex: "…")` literals well over a hundred times across the
    /// app; centralizing them gives the design system one source of truth
    /// (and avoids re-parsing the hex string on every view render).
    static let onyxBlue   = Color(hex: "66CCFF")   // info / running / default accent
    static let onyxGreen  = Color(hex: "6BFF8E")   // success / healthy
    static let onyxAmber  = Color(hex: "FFD06B")   // warning / queued / memory
    static let onyxRed    = Color(hex: "FF6B6B")   // error / failure
    static let onyxPurple = Color(hex: "C06BFF")   // GPU
}
