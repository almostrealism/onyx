import Foundation

/// Recognizes unix-style absolute file paths inside terminal text, so the
/// Cmd+Shift+C overlay can turn them into clickable links the way it does
/// URLs. Deliberately conservative to avoid false positives:
///
///  - A path token is `/segment(/segment)*` where a segment is made only of
///    "ordinary" path characters (letters, digits, and `. _ - + @`). No
///    spaces or exotic punctuation — that keeps fractions, dates, option
///    strings, etc. from looking like paths.
///  - A token counts as a path when it has **≥ 3 slashes**, OR when it
///    starts with one of the user's favorited file-browser folders (so a
///    favorite of `/root` makes `/root/file` clickable even at 2 slashes).
///    A favorite of `/` is ignored — it would match everything.
public enum FilePathDetector {

    /// `/seg(/seg)*` with a conservative segment character class.
    private static let regex = try! NSRegularExpression(
        pattern: "/[A-Za-z0-9._+@-]+(?:/[A-Za-z0-9._+@-]+)*")

    /// Whether a matched `/…` token should be treated as a file path.
    public static func isFilePath(_ token: String, favorites: [String]) -> Bool {
        let slashes = token.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
        if slashes >= 3 { return true }
        for raw in favorites {
            let f = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard f != "/", !f.isEmpty else { continue }   // "/" would match everything
            if token == f || token.hasPrefix(f + "/") { return true }
        }
        return false
    }

    /// NSRanges (in `text`) of every token that qualifies as a file path.
    public static func matchRanges(in text: String, favorites: [String]) -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: full).compactMap { m in
            isFilePath(ns.substring(with: m.range), favorites: favorites) ? m.range : nil
        }
    }

    /// Encode a path into the private `onyxfile://` scheme used as the link
    /// target; the overlay's openURL handler decodes it back with `url.path`.
    public static func linkURL(for path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "onyxfile"
        c.host = "f"
        c.path = path            // already starts with "/"
        return c.url
    }
}
