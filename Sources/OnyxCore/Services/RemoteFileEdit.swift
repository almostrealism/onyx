//
// RemoteFileEdit.swift
//
// Responsibility: The rules for editing a file on a host by hand: what may
//                 be edited, the paths scp and the shell each need, and
//                 the script that puts a saved file in place.
// Scope: Service. Pure — no I/O; FileEditorManager runs what this builds.
//
// The file browser's viewer is NOT a base to edit from. It reads through
// `head -2000` and the remote-script path, which strips carriage returns
// and can carry terminal echo: saving what it shows would truncate long
// files and rewrite every CRLF. So the editor moves the file both ways as
// bytes, with scp, and never through a shell's output.
//
// Saving:
//   1. fetch the file again and compare with what was opened — if it
//      changed on the host, stop and ask rather than overwrite;
//   2. upload the new bytes beside it, as a hidden temporary file;
//   3. `cat temp > file`, then remove temp.
// Step 3 writes INTO the existing file instead of moving the temporary
// over it, so the file keeps its owner, permissions, hard links, and — if
// it's a symlink — stays one, still pointing where it did. The new bytes
// are complete on the host's disk before the file is touched, and the
// temporary is removed only once the copy succeeded, so a failure leaves
// a full copy beside the original.
//

import Foundation

public enum RemoteFileEdit {

    /// Bigger than this isn't hand-editing, and a text view holding it
    /// gets slow.
    public static let maxEditableBytes = 2_000_000

    /// Why a file can't be edited, or nil when it can.
    public static func refusal(for data: Data) -> String? {
        if data.count > maxEditableBytes {
            let mb = Double(data.count) / 1_000_000
            return String(format: "%.1f MB is too big to edit here (the limit is 2 MB).", mb)
        }
        if decode(data) == nil {
            return "Not UTF-8 text, so it can't be edited here without changing its bytes."
        }
        return nil
    }

    /// The bytes as text, only if they round-trip exactly.
    public static func decode(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              Data(text.utf8) == data else { return nil }
        return text
    }

    /// The path as scp should name it. scp speaks SFTP, where no shell
    /// expands `~` — but a path relative to the home directory works,
    /// because that's where an SFTP session starts.
    public static func scpPath(_ path: String) -> String {
        if path == "~" { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)) }
        return path
    }

    /// The path as a POSIX shell word, `~` expanded by the shell itself.
    public static func shellPath(_ path: String) -> String {
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        if path == "~" { return "\"$HOME\"" }
        return quote(path)
    }

    /// The hidden temporary a save uploads to: same directory, so the
    /// copy into place never crosses a filesystem.
    public static func temporaryPath(for path: String, token: String) -> String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let name = ".\(ns.lastPathComponent).onyx-save-\(token)"
        return dir.isEmpty ? name : (dir as NSString).appendingPathComponent(name)
    }

    /// Printed by `commitScript` once the file holds the new bytes.
    public static let savedMarker = "ONYX-SAVED"

    /// Copy the uploaded temporary into the file and remove it. The two
    /// sit in one directory (see `temporaryPath`), so the script `cd`s
    /// there once and names each file by its bare name: a long path costs
    /// its length once, not four times, against the ~1KB a terminal will
    /// take. No `!` and no globs: this runs in an interactive shell (see
    /// CLAUDE.md).
    public static func commitScript(temporary: String, target: String) -> String {
        let dir = (target as NSString).deletingLastPathComponent
        let t = quote((temporary as NSString).lastPathComponent)
        let p = quote((target as NSString).lastPathComponent)
        let cd = dir.isEmpty ? "" : "cd \(shellPath(dir)) && "
        return "\(cd)cat \(t) > \(p) && rm -f \(t) && echo \(savedMarker)"
    }

    /// Single-quoted for a POSIX shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
