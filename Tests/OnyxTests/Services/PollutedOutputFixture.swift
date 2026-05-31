import Foundation
@testable import OnyxLib

/// Shared fixture for simulating remote-output pollution.
///
/// When `ssh -tt` allocates a remote PTY, the kernel TTY discipline echoes
/// our stdin (the wrapped script) back to us *before* `stty -echo` in the
/// script can take effect. The result is that every line of script source
/// appears verbatim in the captured stdout, ahead of any runtime output. On
/// some hosts the echo block is fragmented further by terminal line-wrap.
///
/// These helpers let parser tests construct realistic polluted output by
/// concatenating the source-echo block with whatever runtime body the
/// parser should ultimately extract. The fixtures mirror exactly what
/// `RemoteScript.wrap` produces.
enum PollutedOutputFixture {

    /// Build a captured-stdout sample as: full source echo, then `runtime`,
    /// then the runtime execution marker, then a small ssh-prompt tail (just
    /// like a real ssh -tt session would emit on exit).
    ///
    /// This is the case `RemoteScript.cleanedOutput` is expected to handle
    /// end-to-end — strip the source echo, drop the trailing marker + prompt
    /// noise, and hand the parser only the runtime portion.
    static func fullEchoThenRuntime(script: String, runtime: String) -> String {
        let wrapped = RemoteScript.wrap(script)
        return """
        \(wrapped)
        \(runtime)
        ---ONYX-OK-2---
        user@host:~$ exit
        logout
        Connection to host closed.
        """
    }

    /// As above but with the source echo line-wrapped at column 80 — some
    /// hostile remotes have narrow PTY widths. The boundary heuristic
    /// (`$((1+1))`) must still find the last source-echo line even when it
    /// got split by wrap.
    static func wrappedEchoThenRuntime(script: String, runtime: String,
                                       column: Int = 80) -> String {
        let wrapped = RemoteScript.wrap(script)
        let folded = wrapped.split(separator: "\n").map { wrapLine(String($0), at: column) }
            .joined(separator: "\n")
        return """
        \(folded)
        \(runtime)
        ---ONYX-OK-2---
        """
    }

    /// Pure runtime — what the parser would see if echo really was suppressed.
    /// Used to verify the parser is still correct in the happy path.
    static func cleanRuntime(_ runtime: String) -> String {
        return runtime + "\n---ONYX-OK-2---\n"
    }

    private static func wrapLine(_ line: String, at column: Int) -> String {
        guard line.count > column else { return line }
        var chunks: [String] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            let next = line.index(idx, offsetBy: column, limitedBy: line.endIndex) ?? line.endIndex
            chunks.append(String(line[idx..<next]))
            idx = next
        }
        return chunks.joined(separator: "\n")
    }
}
