import Foundation

/// Normalizes the "smart"/stylized punctuation macOS substitutes for plain
/// ASCII back to the plain characters. Quotation marks are the headline
/// case — the system auto-converts a typed `"` into curly `“`/`”` — but the
/// same substitution machinery also produces smart dashes and an ellipsis
/// glyph, so we strip all of them.
///
/// This is the guaranteed backstop: even if a stylized character arrives via
/// paste (where live substitution-disabling can't help), running text through
/// `sanitize` before it is stored or committed forces it back to ASCII.
public enum TextSanitizer {

    /// Stylized → plain. Em dash becomes "--", en dash "-", ellipsis "...".
    private static let replacements: [Character: String] = [
        "\u{201C}": "\"",   // “  left double quotation mark
        "\u{201D}": "\"",   // ”  right double quotation mark
        "\u{201E}": "\"",   // „  low double quotation mark
        "\u{201F}": "\"",   // ‟  high-reversed double quotation mark
        "\u{2033}": "\"",   // ″  double prime
        "\u{2018}": "'",    // ‘  left single quotation mark
        "\u{2019}": "'",    // ’  right single quotation mark / apostrophe
        "\u{201A}": "'",    // ‚  low single quotation mark
        "\u{201B}": "'",    // ‛  high-reversed single quotation mark
        "\u{2032}": "'",    // ′  prime
        "\u{2013}": "-",    // –  en dash
        "\u{2014}": "--",   // —  em dash
        "\u{2026}": "...",  // …  horizontal ellipsis
    ]

    /// True if `s` contains any character we would rewrite.
    public static func containsStylized(_ s: String) -> Bool {
        s.contains { replacements[$0] != nil }
    }

    /// Replace every stylized character with its plain equivalent. Returns
    /// the input unchanged (no allocation) when there's nothing to do.
    public static func sanitize(_ s: String) -> String {
        guard containsStylized(s) else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let plain = replacements[ch] { out += plain } else { out.append(ch) }
        }
        return out
    }
}
