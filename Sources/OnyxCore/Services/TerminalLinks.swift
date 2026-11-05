//
// TerminalLinks.swift
//
// Responsibility: Which links found in terminal output a click may open.
// Scope: Stateless.
//

import Foundation

public enum TerminalLinks {

    /// Schemes a click in the terminal opens. Output is anyone's — a
    /// remote host's, a log's, a web page cat'ed by mistake — so a click
    /// opens web and mail links only, never `file:`, `ssh:` or an app's
    /// custom scheme that would run something on this Mac.
    public static let schemes: Set<String> = ["http", "https", "mailto"]

    /// The URL for a link's text, if a click may open it. Trailing
    /// punctuation that ends a sentence rather than the URL is dropped.
    public static func openable(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,;:!?'\"".contains(last) { trimmed.removeLast() }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty ?? true { return nil }
        return url
    }
}
