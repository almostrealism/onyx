# Onyx — Project Guide for Claude

Onyx is a macOS terminal-first overlay app: jet-black translucent window, always-connected SSH + tmux sessions, built-in notes, command palette, file browser with git integration, monitoring overlay, Claude Code hook integration, browser tabs, and more.

## Build & test

```
swift build     # or ./run.sh
swift test
```

Dependencies: SwiftTerm 1.2+ via SPM. Main target `Onyx` is an executableTarget that links `OnyxLib` (the bulk of the code). `OnyxMCP` is a separate cross-platform (macOS + Linux) executable.

## Layered architecture

`Sources/OnyxLib/` is organized into strict layers. A file may only depend on files in layers **below** it. Never introduce upward or sideways dependencies.

```
Views        ← SwiftUI views, NSViewRepresentables (presentation only)
  │
  ├── App    ← AppState, AppDelegate, KeyboardShortcuts (top-level orchestration)
  │
Managers     ← Per-window / per-session stateful coordinators (ObservableObjects)
  │
Stores       ← Shared singletons, disk-persisted cross-window state
Services     ← Stateless utilities (SSH builders, MCP, Dashboard, syntax highlight, etc.)
  │
Models       ← Pure data types; no dependencies on anything else
```

### What belongs in each layer

**Models** — Plain data. Structs, enums, simple value types. No `ObservableObject`, no disk I/O, no timers. A file that wouldn't need to change if the UI were swapped out belongs here.
- `SessionModels.swift` — `SessionSource`, `TmuxSession`
- `HostConfig.swift` — `HostConfig`, `SSHConfig`, `AppearanceConfig`
- `ConnectionModels.swift`, `ArtifactModels.swift`, `FileBrowserModels.swift`, `GitModels.swift`, `MonitorSample.swift`

**Services** — Stateless helpers that operate on models. Free functions, static methods, or classes without meaningful identity. Depend only on Models.
- `SyntaxHighlighter.swift` — code → `AttributedString`
- `DependencyAnalyzer.swift` — embedded Python script for Java dep graphs
- `MCPServer.swift` — MCP JSON-RPC server (Unix socket + TCP)
- `DashboardServer.swift` — HTTP server for browser dashboard

**Stores** — Shared singletons (one instance across the whole app). Disk-persisted. Thread-safe. Depend on Models and Services.
- `FavoritesStore`, `AppearanceStore`, `NetworkTopologyStore`, `TimingDataStore`
- A new Store should be justified by: cross-window sharing, persistence, or both.

**Managers** — Per-window or per-session stateful `ObservableObject`s that coordinate work for one UI context. One Manager owns a specific responsibility end-to-end.
- `ConnectionPair` / `ConnectionPairRegistry` — THE SSH transport. Exactly two mux masters per host (active + standby), instant standby promotion, single `HostHealth` authority, NWPathMonitor + sleep/wake handling, orphan reaper, airtight shutdown. Everything that talks to a host rides these two connections as mux channels (`ControlMaster=no`); nothing else may open a TCP connection to a host.
- `TerminalSessionManager` (`OnyxTerminalView`) — terminal pool, session spawn as pair channels, pair-aware instant reattach, enumeration, health checks, single writer of `sessionConnectionStates`
- `MonitorManager` — per-host CPU/GPU/docker/timing polling
- `DockerStatsManager` — docker stats sub-polling
- `GitManager` — git status/diff/log over SSH
- `BrowserManager` — WKWebView pool + KVO-based state
- `FileBrowserManager` — file listing, search, recent files
- `ArtifactManager` — diagram/model/text artifacts
- `NotesManager`, `ClaudeSessionManager`, `TimingManager`

Managers depend on Stores, Services, and Models — not on Views or other Managers (prefer communication through AppState or Stores).

**App** — Top-level orchestration. `AppState` wires Managers and Stores together and exposes state to Views. `AppDelegate` handles window styling. `KeyboardShortcuts` routes global shortcuts per window.

**Views** — SwiftUI `View`s and `NSViewRepresentable`s. Presentation and user-interaction handling only. Views may read from Managers/Stores/AppState and call their methods, but should not contain business logic. When a View is starting to grow logic, extract to a Manager.

### Dependency rules (enforced by convention)

1. **Never** import a higher layer from a lower one. Models can't reference Managers; Services can't reference Views.
2. **Managers talk through Stores or AppState**, not to each other directly. If two Managers need shared state, it belongs in a Store or AppState.
3. **Views are dumb.** If a view computes something non-trivial, that logic probably belongs in a Manager.
4. **Async boundaries preserve identity.** Any manager that acts on "the active session" must re-verify `appState.activeSession?.id` at every `DispatchQueue.main.async` / `asyncAfter` boundary. See `TerminalSessionManager` for the pattern (reconnect safety).

## Key architectural lessons

- Running SPM executables on macOS requires `NSApplication.shared.setActivationPolicy(.regular)` for proper GUI behavior.
- `NSVisualEffectView` must NOT be injected into SwiftUI's contentView via AppDelegate — use `NSViewRepresentable` instead.
- Background ZStack layers need `.allowsHitTesting(false)` to pass events through.
- WKWebView state must NOT be read from `@Published` properties during SwiftUI `updateNSView` — it causes re-entry loops. Use KVO observations instead (`BrowserManager` pattern).
- SSH ControlMaster paths must live in a directory without spaces — `~/.onyx/` not `~/Library/Application Support/`.
- Broken pipe recovery: report via `appState.reportSSHFailure(host:)` — the host's `ConnectionPair` marks its active connection suspect and promotes the warm standby immediately. Never delete mux sockets by hand.
- SSH-driven pollers must gate on `appState.hostUsable(host)` and claim a slot with `appState.acquireUtilityChannel(label:host:)` (in-flight dedup + per-host cap) — this is what prevents poll pileup on slow networks.
- `HostConfig.paused` is the user's "leave this host alone" switch (Settings → HOSTS). A paused host reports `HostConnectionState.paused` (never usable), its pair tears both masters down and then costs zero ssh calls per tick, enumeration skips it, and terminals show `SessionConnectionState.hostPaused` instead of retrying. Any new remote feature must respect it — `hostUsable` and `acquireUtilityChannel` both refuse paused hosts, so gate on those.
- Topology-based session enumeration never wipes the session list on a single failed `docker ps` — it uses a grace period via `NetworkTopologyStore`.

## Remote command execution

**Before writing any new SSH-driven feature, read this section.** Hostile remote shells are real, and the lesson is hard-won.

### The trap

The naive pattern `ssh user@host "<command>"` invokes `$SHELL -c "<command>"` on the remote. If the remote login shell has `set -n` (noexec) turned on — via system bashrc, `BASH_ENV`, or an exotic `$SHELL` — **the command never runs**. The script source is echoed back via `set -v` (verbose) and our parser silently sees no real output. Every variant fails the same way: `sh -c`, `bash --norc -ic`, even `ssh -tt … bash -ic`. The outer shell is in noexec before our argument can run anything inside it.

### The fix

For any data-reading SSH command, **don't pass a command argument to ssh**. `ssh -tt user@host` (no command) starts the remote `$SHELL` *interactively* — bash's "interactive disqualified by `-c`" rule doesn't apply, the shell ignores `set -n`, and `BASH_ENV` is only sourced for non-interactive shells. Drive the shell by piping the script via stdin.

This pattern is encapsulated in `Services/RemoteScript.swift` and `AppState.remoteScript(_:host:)`. Use them.

```swift
// Good — RemoteScript-based, noexec-safe:
let (cmd, args, stdin) = appState.remoteScript("git status --porcelain")
guard let output = FileBrowserManager.runRemoteScript(cmd: cmd, args: args, stdin: stdin) else {
    // execution failed (noexec or connection error) — keep stale data
    return
}
// `output` is already cleaned: \r stripped, execution marker removed

// Bad — vulnerable to noexec hosts:
let (cmd, args) = appState.remoteCommand("git status --porcelain")
let output = FileBrowserManager.runProcess(cmd: cmd, args: args)  // empty/garbage on broken hosts
```

### When `remoteCommand` is still OK

`remoteCommand` (the legacy `$SHELL -lc` pattern) is acceptable for **fire-and-forget side effects** where graceful failure on broken hosts is fine: hook setup (mkdir/chmod), MCP port cleanup. New uses should justify why noexec failure is harmless.

### Interactive sessions are inherently safe

`sshCommand`, `dockerTmuxCommand`, `dockerLogsCommand`, `dockerTopCommand` all open interactive remote sessions (tmux, docker exec -it, streaming `docker logs -f`). The remote shell IS interactive, so `set -n` is ignored. These don't need `remoteScript` and shouldn't be migrated — TTY allocation `-t` is enough.

### The interactive shell cuts both ways

Driving an *interactive* shell is what defeats noexec — but interactive shells also turn on features a script never sees. Two have already cost us working hosts, both silently:

- **`!` is history expansion.** zsh meets `case "$x" in *[!0-9]*)`, tries to expand `!0`, prints `event not found` and **discards the entire line**. The script is one line, so the whole poll vanishes: no output, no exit code worth reading, the session left waiting until we kill it. Never put `!` in a remote script — use `[ "$x" -ge 0 ] 2>/dev/null` instead of a negated glob class.
- **An unmatched glob is fatal in zsh** (`nomatch` is on by default), where sh/bash pass the pattern through. `for d in /sys/class/drm/card*/device` aborts the script on any host without that path. Iterate a directory listing instead: `for c in $(ls /sys/class/drm 2>/dev/null)`.

`AppStateTests` locks both: the stats script must contain no `!` and no path-position `*`. Add to those tests when you add a new remote script.

**A terminal cannot be written to at full speed.** `-tt` means the far end is a terminal, and a terminal's input buffer is ~1KB on macOS (4KB on Linux). The remote shell reads a line, runs it (`top` takes ~0.5s), and everything still arriving piles into that buffer and is **discarded** once it's full — the shell then waits forever for the rest of a line, and the caller sees only the login banner before its watchdog fires. `RemoteExec.writePaced` delivers stdin in 512-byte chunks 60ms apart — necessary, but not sufficient: measured against a real host, a 2.2KB script unpaced returned *nothing*, and paced returned only its first sections (a CPU reading, then truncation before MEM, and no `exit`, so the session hung). **Keep each payload under ~1KB in total** and split anything bigger into a second command (see `AppState.acceleratorCommand`, which is also gated to hosts that can answer it).

This ceiling has now bitten three separate features, and it always looks the same from the outside: the feature silently reports nothing, with no error anywhere. Watch for scripts whose size scales with something — the git status script named the repo path eight times (broken past ~30 characters of path), and the file-search script named every selected file extension (broken with the type filter fully enabled). Name a path once by `cd`-ing to it; if a list can't be bounded, send the unfiltered query and filter the results locally (`FileBrowserManager.searchCommand`). This is not theoretical: ~900 bytes of added GPU probing silently killed stats on every Mac while Linux hosts were unaffected.

**Errors come back on stdout.** With `ssh -tt` the remote's complaints arrive over the PTY mixed into stdout, not stderr — so a failing poll's stderr is often empty while the real message ("zsh: event not found") sits in the output we captured. `MonitorManager.remoteComplaint(in:)` digs it out; surface it rather than reporting a timeout.

### Detecting noexec failure

`RemoteScript.executionVerified(in: output)` checks for `---ONYX-OK-2---`. The marker uses `$((1+1))` — only an actually-evaluating shell emits the literal `2`; a noexec shell echoes the unevaluated form. `RemoteScript.nonExecutionDiagnostic` is the canonical user-facing message.

### Tests

`Tests/OnyxTests/App/AppStateTests.swift` locks the shape of every SSH command builder. If you add a new one, add a regression test there: vulnerable patterns should fail at test time, not on a user's broken remote a year later.

## Feedback

- [Commit regularly](.claude/feedback_commit_regularly.md) — commit after each completed feature without being asked.
