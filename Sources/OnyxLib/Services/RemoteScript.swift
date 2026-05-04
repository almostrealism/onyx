//
// RemoteScript.swift
//
// Responsibility: Stateless helpers for safely running shell scripts on
//                 a remote (or local) host. Encodes the noexec-safe
//                 invocation pattern we discovered after a long debug
//                 session: hostile remote shells can be in `set -n`
//                 (noexec) mode, refuse `-c` commands, and silently echo
//                 the script source instead of running it. The pattern
//                 here defeats every common variant.
// Scope: Service (stateless, no state, no I/O). Callers compose this
//        with their SSH config to build a final invocation.
// Threading: Pure functions — safe to call from any thread.
//
// Background:
//   We tried `sh -c`, `ssh -tt`, `bash --norc -ic` — all failed because
//   sshd invokes `$SHELL -c "<our argument>"` on the remote, and on the
//   broken host the outer shell was already in noexec before our argument
//   could run anything inside it.
//
//   The fix is to NOT pass a command argument to ssh at all. `ssh -tt
//   user@host` (no command) starts the user's `$SHELL` *interactively*
//   — bash's "interactive disqualified by -c" rule doesn't apply because
//   there's no -c. Interactive shells ignore `set -n`, and BASH_ENV is
//   only sourced for non-interactive shells, so both common noexec
//   triggers are defeated. We drive the shell by piping the script via
//   stdin.
//
//   The execution-proof marker uses shell arithmetic so a printing-only
//   shell (set -nv) can't fake it: `$((1+1))` only evaluates to "2" if
//   the shell actually ran the line. A noexec shell echoes the literal
//   `$((1+1))` instead, which doesn't match.
//
// See: CLAUDE.md "Remote command execution" — must read before writing
//      any new SSH-driven feature.
//

import Foundation

/// Stateless helpers for running shell scripts on remote hosts safely.
/// Pair with `AppState.remoteScript(...)` which combines this with SSH
/// config to build the actual invocation.
public enum RemoteScript {
    /// Marker the wrapped script appends. The literal "2" only appears
    /// in output if the shell evaluated `$((1+1))` — a printing-only
    /// shell would emit the unevaluated form, so this can't be spoofed
    /// by `set -nv` source-echo.
    public static let executionMarker = "---ONYX-OK-2---"

    /// Standard system tool locations appended to whatever PATH the
    /// remote process inherits. Covers Linux (/usr/bin, /usr/sbin),
    /// macOS Homebrew (/usr/local/bin), and Apple Silicon Homebrew
    /// (/opt/homebrew/bin) so tools like `top`, `nvidia-smi`, `docker`,
    /// `git` are findable without sourcing the user's login profile.
    public static let standardPath =
        "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Wrap `script` with the safety prelude (PATH setup, defensive
    /// `set +vx` to suppress verbose mode if a profile turned it on)
    /// and the execution-proof marker. The result is what gets fed to
    /// the remote shell.
    public static func wrap(_ script: String) -> String {
        return """
        set +vx 2>/dev/null
        PATH="${PATH:-}:\(standardPath)"
        \(script)
        echo "\(executionMarkerEcho)"
        """
    }

    /// True iff the marker is in the captured output, proving the
    /// wrapped script actually ran on the remote (vs. being printed
    /// without execution by a noexec shell).
    public static func executionVerified(in output: String) -> Bool {
        output.contains(executionMarker)
    }

    /// Normalize and clean output before parsing:
    ///  - Strip `\r` (ssh -tt produces `\r\n` line endings).
    ///  - Remove the trailing execution marker line so callers don't
    ///    have to filter it themselves.
    public static func cleanedOutput(_ output: String) -> String {
        return output
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: executionMarker, with: "")
    }

    /// User-facing message for output that came back without the
    /// execution marker — almost always means the remote shell is in
    /// noexec mode.
    public static let nonExecutionDiagnostic = """
    Stats script did not execute on the remote — only its source came back. \
    The remote login shell is likely refusing to run `-c` commands (e.g. it \
    has `set -n` or a similar dry-run mode in its profile).
    """

    /// The shell expression used in the wrapped script. The unevaluated
    /// form (`$((1+1))`) is what a noexec shell would echo back.
    private static let executionMarkerEcho = "---ONYX-OK-$((1+1))---"
}
