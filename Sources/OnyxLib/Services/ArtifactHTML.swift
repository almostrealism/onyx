//
// ArtifactHTML.swift
//
// Responsibility: Preparing agent-authored HTML for display — deciding
//                 whether it's a whole document or a fragment, and
//                 giving a fragment somewhere readable to live.
// Scope: Service. Pure string work, so the decisions are testable
//        without a web view.
//
// The rule: a full document is shown EXACTLY as written. An agent that
// produced a styled status page has already decided what it should look
// like, and second-guessing that would break the page it tested. Only a
// bare fragment gets wrapped, because a fragment has no styling at all
// and the panel it lands in is black — unstyled text on it is invisible.
//

import Foundation

public enum ArtifactHTML {

    /// Whether this is a complete document rather than a fragment.
    ///
    /// Looks for the structural markers only, and only near the start:
    /// a page that merely mentions `<html>` inside a code sample is a
    /// fragment that talks about HTML, not a document.
    public static func isFullDocument(_ html: String) -> Bool {
        let head = html
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(512)
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    /// What to hand the web view.
    ///
    /// Full documents pass through untouched. Fragments are wrapped in a
    /// shell that matches the app: dark background, readable text, and
    /// table/link styling, since a status page is mostly links and tables
    /// and an agent writing a fragment hasn't styled either.
    public static func prepared(_ html: String) -> String {
        guard !isFullDocument(html) else { return html }
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: dark; }
          body {
            background: transparent;
            color: rgba(255,255,255,0.85);
            font: 13px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            line-height: 1.55;
            margin: 0;
            padding: 16px;
            -webkit-font-smoothing: antialiased;
          }
          a { color: #66ccff; }
          h1, h2, h3 { color: #fff; line-height: 1.25; }
          h1 { font-size: 1.5em; } h2 { font-size: 1.25em; } h3 { font-size: 1.05em; }
          code, pre {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 12px;
          }
          pre {
            background: rgba(255,255,255,0.05);
            padding: 10px; border-radius: 5px;
            overflow-x: auto;
          }
          /* A status page is mostly a table; an unstyled one is unreadable
             against a dark panel. */
          table { border-collapse: collapse; width: 100%; }
          th, td {
            text-align: left; padding: 6px 10px;
            border-bottom: 1px solid rgba(255,255,255,0.10);
          }
          th { color: rgba(255,255,255,0.55); font-weight: 500; font-size: 11px;
               text-transform: uppercase; letter-spacing: 0.06em; }
          blockquote {
            margin: 0; padding-left: 12px;
            border-left: 2px solid rgba(255,255,255,0.15);
            color: rgba(255,255,255,0.6);
          }
        </style></head>
        <body>
        \(html)
        </body></html>
        """
    }

    /// Whether a navigation should leave the panel.
    ///
    /// The artifact panel is a viewport onto one page, not a browser:
    /// following a link inside it would replace the status page an agent
    /// just published, with no way back. Anything with a real scheme
    /// opens outside instead; in-page anchors stay put.
    public static func shouldOpenExternally(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        // about:blank and the initial load aren't navigations the user made.
        if scheme == "about" { return false }
        // A fragment on the current page is in-page movement, not a link out.
        if url.absoluteString.hasPrefix("#") { return false }
        return true
    }
}
