//
// TerminalDrop.swift
//
// Responsibility: Turning a file dropped on the terminal into a path the
//                 shell on the other end can actually open — which means
//                 uploading it first when the other end is a different
//                 machine.
// Scope: Service-ish helpers + the view's drop handling (see the
//        NSDraggingDestination methods on OnyxTerminalView).
//
// Terminal.app inserts the dropped file's path, and Claude Code has made
// that the way people point an agent at a file. That gesture is a lie
// over SSH: the path exists on the Mac and means nothing to the shell
// you're typing into. So a drop on a remote session copies the file over
// first and inserts the path it landed at.
//

import Foundation

public enum TerminalDrop {

    /// Where uploads land on a remote host.
    ///
    /// Not `mktemp -d`, and not $TMPDIR: reading either back needs a
    /// round trip through a remote shell, which is the part of this
    /// codebase that keeps breaking on hostile shells. A fixed path under
    /// the home directory needs no query, is writable on every platform
    /// we support, has no spaces in it (the reason ~/.onyx exists at all
    /// for control sockets), and — unlike /tmp — survives the reboot
    /// between dropping a file and getting round to using it.
    ///
    /// scp resolves relative destinations against the home directory, so
    /// the upload never has to expand `~` in a remote shell either.
    public static let remoteRelativeDir = ".onyx/dropped"
    /// The same directory as the user should see it.
    public static let remoteDisplayDir = "~/.onyx/dropped"
    /// Inside a container, where a home directory may not exist.
    public static let containerDir = "/tmp/onyx-dropped"

    /// Shell-escape a path for insertion at a prompt.
    ///
    /// Single quotes rather than backslashes: a path can contain spaces,
    /// parentheses, `&`, `$`, and quoting the whole thing handles every
    /// one of them the same way. The inserted text is meant to be
    /// runnable as-is, not merely readable.
    public static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What to type into the terminal for a set of paths.
    ///
    /// Space-separated and trailing-spaced, matching Terminal.app: you
    /// drop a file after typing a command and the cursor is left ready
    /// for the next argument.
    public static func insertionText(for paths: [String]) -> String {
        guard !paths.isEmpty else { return "" }
        return paths.map(quoted).joined(separator: " ") + " "
    }

    /// The remote filename for a dropped file.
    ///
    /// The basename is kept — an agent being pointed at a file usually
    /// cares what it's called — but anything that would let a filename
    /// escape its directory or confuse a shell is replaced. A file named
    /// `../../.ssh/authorized_keys` must not be able to write there.
    public static func safeRemoteName(for url: URL) -> String {
        let base = url.lastPathComponent
        let cleaned = base.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            if ch == "." || ch == "-" || ch == "_" { return ch }
            return "_"
        }
        var name = String(cleaned)
        // A leading dot-dot can survive the filter above ("..").
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "dropped-file" }
        return String(name.prefix(120))
    }
}
