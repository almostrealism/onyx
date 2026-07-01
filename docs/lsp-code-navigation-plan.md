# LSP Code Navigation — Implementation Plan

Status: **M0–M3 implemented** · Author: pairing session, 2026-07 · Transport
decision recorded in `docs/adr/ADR-007-lsp-no-pty-transport.md`. The original
proving spike (`Sources/JDTLSSpike`) has been retired; `spike/sample-java`
remains as the integration-test fixture.

## Goal

Give the file browser real, IDE-grade Java navigation:

- **subclasses** of a class · **implementors** of an interface · **overrides**
  of a method · **references** to a symbol · **go-to-definition** ·
  (later) **call hierarchy**.

Powered by the Eclipse JDT language server (`jdtls`) running **on the remote
host** and driven over SSH. The spike proved every one of these round-trips
correctly, both locally and over SSH, so what follows is engineering, not
research. Java only for now; the transport is LSP so other languages are later
a different server, not new plumbing.

## What the spike settled (constraints, not choices)

1. **Transport is a clean byte pipe — no PTY.** LSP is `Content-Length`-framed
   bytes; `ssh -t` echoes stdin and rewrites newlines and corrupts framing. The
   launch command must use `sshSessionArgs` **minus `-t`**. This is the
   opposite of `sshCommand`/`dockerTmuxCommand`, and it's safe from the noexec
   trap because jdtls is a real `exec`, not a shell command. *(Note: the obvious
   pattern-match — copy `sshCommand` and keep `-t` — is wrong. Do not.)*
2. **The frame reader must tolerate leading banner noise** (a login shell may
   print MOTD before the first frame). Scan for `Content-Length:`; don't assume
   a clean stream.
3. **Server→client requests must be answered or jdtls stalls:**
   `workspace/configuration`, `client/registerCapability`,
   `window/workDoneProgress/create`. Null/minimal replies suffice.
4. **Readiness = `language/status` with `type == "ServiceReady"`**, with a
   query-polling fallback (re-issue until non-empty) for robustness.
5. **First import is slow** (Maven/Gradle resolution) and must be async, with a
   `$/progress`-driven "indexing…" state.
6. **The `-data` workspace dir is locked** — a second jdtls against the same dir
   fails silently. The manager must serialize per workspace and never
   double-spawn.
7. Positions are **0-based UTF-16**. Primitives:
   `textDocument/prepareTypeHierarchy` → `typeHierarchy/{sub,super}types`;
   `textDocument/implementation` (implementors *and* overrides);
   `textDocument/references`; `textDocument/definition`.

## Architecture — new files by layer

Respecting `docs/adr/ADR-006-layered-architecture.md` (Models → Services →
Stores → Managers → App → Views; no upward/sideways deps).

| Layer | File | Responsibility |
|---|---|---|
| **Models** | `LSPModels.swift` | LSP wire types: `LSPPosition`, `LSPRange`, `LSPLocation`, `TypeHierarchyItem`, `SymbolKind`, JSON-RPC envelopes. Pure `Codable`. |
| **Models** | `CodeNavModels.swift` | UI-facing: `NavKind` (subtypes/supertypes/implementation/references/definition), `NavResult` (path, line, symbol, snippet), `NavResultGroup` (by file). |
| **Services** | `LSPProtocol.swift` | **Stateless** framing: encode `Content-Length` frames; incremental, banner-tolerant decode of a byte buffer → `[LSPMessage]`. Ported from the spike's `nextFrame()`. Pure → heavily unit-tested. |
| **Services** | `JDTLSBootstrap.swift` | Builds the install script (download snapshot → `~/.onyx/jdtls`) and the Java-21/python3 preflight probe. No I/O itself — returns scripts for `remoteScript`. |
| **App** | `AppState.swift` (+`remoteLSPCommand`) | SSH launch-command builder for jdtls. Sits beside `sshCommand`/`dockerTmuxCommand`. **No `-t`, no MCP forwarding.** |
| **Managers** | `LSPManager.swift` | Owns per-workspace jdtls servers; public `navigate(...)` API; lifecycle, readiness, teardown; per-host keyed (ADR-004); identity-reverified (ADR-001). |
| **Managers** | `LSPSession.swift` | One jdtls connection: `Process` + pipes + background reader + request/response correlation + notification handling. Generalization of the spike's `LSPClient`. |
| **Views** | `CodeNavResultsView.swift` | Grouped-by-file results panel; mirrors the existing search-results styling. |
| **Views** | (edits) `FileBrowserView.swift` | Nav entry points on the viewer + jump-to-line in `SelectableCodeView`. |
| **Config** | `HostConfig.swift` (+`CodeIntelConfig`) | Per-host: `enabled`, `jdtlsPath`, `heapMB`. |

## Component design

### LSPProtocol (Service, pure)

The riskiest logic (frame parsing) becomes the most testable. API roughly:

```swift
enum LSPProtocol {
    static func encode(_ message: [String: Any]) -> Data          // Content-Length frame
    static func decode(_ buffer: inout Data) -> [[String: Any]]    // consume complete frames
}
```

`decode` drains every complete frame from `buffer`, leaving partial bytes for
next time, and discards pre-header banner noise. This is the spike's
`nextFrame()` made pure and buffer-in/buffer-out.

### AppState.remoteLSPCommand (App)

```swift
/// Launch jdtls on a host over a CLEAN byte pipe. Unlike sshCommand/
/// dockerTmuxCommand this MUST NOT allocate a TTY — LSP is framed bytes and a
/// PTY corrupts the stream (see the jdtls spike). No MCP forwarding either.
public func remoteLSPCommand(host h: HostConfig, launch: String) -> (String, [String]) {
    if h.isLocal {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shell, ["-lc", "export \(extraPath); \(launch)"])
    }
    var args = sshSessionArgs(for: h)          // long-lived, no mux
    // deliberately NO "-t"
    args.append(sshUserHost(for: h))
    args.append("exec $SHELL -lc 'export \(extraPath); \(launch)'")
    return ("/usr/bin/ssh", args)
}
```
where `launch` is `\(jdtlsPath) -data \(workspaceDataDir)`.

### LSPSession (Manager-internal)

The spike's `LSPClient`, hardened: spawns via `remoteLSPCommand`, registers the
ssh PID with `RemoteExec` (so orphan reaping/cleanup covers it), background
`FileHandle.readabilityHandler` feeding `LSPProtocol.decode`, an id→continuation
map for requests, auto-answers server→client requests, surfaces notifications
(`language/status`, `$/progress`). Exposes `async` request methods.

### LSPManager (Manager)

- **State:** `sessions: [WorkspaceKey: LSPSession]`, `WorkspaceKey =
  (hostID, projectRoot)`. Per-host isolation per ADR-004.
- **Public API (called by Views):**
  ```swift
  func navigate(_ kind: NavKind, file: String, line: Int, char: Int,
                host: HostConfig) async throws -> [NavResultGroup]
  ```
- **Lifecycle:** lazily start a session on first query for a workspace;
  **serialize start** per workspace (the `-data` lock, finding #6); await
  readiness (`ServiceReady`), then `didOpen` the target file with the exact
  bytes the viewer renders; run the query with the poll-until-nonempty fallback.
- **Workspace root detection:** see "Workspaces vs. favorites" below.
- **Teardown:** idle-evict (timer, e.g. 10 min no queries → shutdown+exit); on
  host switch, window close, and sleep — hook the existing cleanup points
  (`cleanupStaleMuxSockets`, terminal teardown). Cap concurrent servers
  (idle-evict the LRU) to bound JVM memory.
- **Threading:** reader off-main; results marshalled to main; **re-verify the
  active host/workspace at every async boundary** before mutating published
  state (ADR-001 pattern, as `TerminalSessionManager.reconnect()` does).

### Workspaces vs. favorites

**A favorite is not a workspace, and neither derives from the other.** A
favorite (`SavedFolder`) is a UI bookmark — navigation only, can sit anywhere
(a whole repo, a deep `src/main/java/...` subdir, or a dir holding several
unrelated projects). A **workspace** is a *build/project root* that jdtls
imports, defined by the code's structure. Conflating them is the trap; keeping
them orthogonal dissolves the nesting/overlap questions.

**Resolution** — on a nav query for a file, walk *up* from the file:

1. **`.git` is the hard ceiling** — a workspace never spans more than one repo,
   and we never ascend past the repo root.
2. Workspace root = the **highest** dir (up to the git root) containing a build
   file (`pom.xml` / `settings.gradle[.kts]` / `build.gradle[.kts]`). *Highest,
   not nearest*, so a **multi-module aggregator wins over a leaf module** and
   jdtls resolves cross-module. (Nearest would silently break that.)
3. No build file up to the git root → workspace = git root (looser mode). No
   `.git` → fall back to the enclosing favorite/browsed dir, capped at a max
   ascent so we never wander to `/`.

**Consequences (the answers to the obvious questions):**

- **Not** one workspace per favorite. Workspaces are **discovered lazily** from
  the first query in a project — we never pre-spin a JVM per favorite.
- A **favorite nested in another favorite** is a non-issue: both resolve *up* to
  the same root → **one workspace, one jdtls**, deduped by resolved root path.
- Existing browser concepts (`SavedFolder`, `activeFolders`, `currentPath`) are
  **unchanged and navigation-only**. "Workspace" is an internal grouping keyed
  `(hostID, resolvedRoot)`; the user at most sees an "indexing *root*…" hint.
- A **monorepo favorite** holding several projects correctly yields several
  scoped workspaces (different files → different roots); the concurrent-server
  cap + idle-evict keep it bounded.
- A file that resolves to **no project** → nav degrades gracefully (disabled /
  "no project" state), never a spurious server.

### UI

- **Entry points:** the viewer already tracks `browser.currentSelection`
  (`SelectableCodeView.onSelectionChange`). Add a nav action bar / context menu
  in `FileContentView` — "Subclasses · Implementors · References · Definition"
  — operating on the current caret/selection (NSTextView range → line/char).
  Plus command-palette entries.
- **Results:** `CodeNavResultsView` renders `[NavResultGroup]` (grouped by
  file), styled like `SearchResultsView`. Selecting a row calls a new
  `browser.openAtLocation(path:, line:)`.
- **Jump-to-line (new capability — the viewer has none today):** add
  `targetLine: Int?` to `FileBrowserManager`; `openAtLocation` reads the file
  then sets it; `SelectableCodeView` converts line→character offset, then
  `setSelectedRange` + `scrollRangeToVisible` + a transient highlight.

### Config & bootstrap

- `CodeIntelConfig { enabled: Bool; jdtlsPath: String; heapMB: Int }` nested in
  `HostConfig`. **Codable back-compat:** add to `CodingKeys`, `decodeIfPresent
  ?? default` in `init(from:)`, and update any HostConfig roundtrip/count
  tripwire test (cf. the `AppearanceConfig` count test in `ModelsTests`).
- **Install affordance:** when a host has Java 21 but no jdtls, surface "Set up
  code intelligence" → runs `JDTLSBootstrap` install script (download snapshot
  to `~/.onyx/jdtls`). Preflight probes Java ≥21 and python3; clear error if
  absent.

## Test strategy

- **LSPProtocol (pure, high-value):** frame round-trip; partial/incremental
  frames split across reads; multiple frames in one buffer; leading banner
  noise discarded; oversized-buffer guard. These are the bugs that bite.
- **remoteLSPCommand (regression, mirrors AppStateTests):** `cmd ==
  /usr/bin/ssh`; **asserts `-t` and `-tt` are ABSENT**; last arg is the
  `exec $SHELL -lc …` launch; local branch uses `$SHELL -lc`. This test is the
  guardrail against someone "fixing" it back to a TTY.
- **LSPModels:** decode captured real jdtls payloads (grab a few from the spike)
  into typed models.
- **LSPManager:** inject a fake `LSPSession`/transport to unit-test routing,
  readiness gating, workspace-root detection, and teardown without a live JVM.
- **Integration:** a live end-to-end test behind `OnyxIntegrationTests`, gated
  like other SSH-dependent tests; reuse `spike/sample-java` as the fixture.

## Phasing (each milestone independently shippable)

- **M0 — Protocol core, no UI.** `LSPModels` + `LSPProtocol` +
  `remoteLSPCommand` + their tests. Port the spike's framing. Invisible to
  users; fully tested.
- **M1 — Vertical slice.** `LSPManager`/`LSPSession`, single-workspace
  lifecycle, **"Show implementors" from the viewer → results panel →
  jump-to-line.** First real user value; exercises the whole stack end-to-end.
- **M2 — Full query set + polish.** subtypes/supertypes/references/definition;
  grouped results; `$/progress` import UI; idle shutdown; teardown hooks; config
  surface.
- **M3 — Bootstrap + robustness.** install affordance + preflight; multi-
  workspace + memory caps; call hierarchy; error/empty states; an ADR capturing
  the no-PTY transport decision.

## Risks & open questions

- **First-import latency** on large monorepos — mitigate with async + progress
  and a configurable heap (`heapMB`).
- **Position fidelity** — didOpen the exact bytes rendered (viewer is
  read-only, so no drift), avoiding disk-vs-buffer mismatches.
- **Memory** — one JVM per workspace; cap concurrent servers, idle-evict LRU.
- **jdtls version churn** — pin a snapshot in `JDTLSBootstrap` rather than
  always-latest, so upgrades are deliberate.
- **Workspace root ambiguity** — nested modules; start with nearest build file,
  revisit if multi-module projects mis-resolve.

## Cleanup

Retire the spike (`Sources/JDTLSSpike`, the `jdtls-spike` target,
`spike/README.md`) once M1 lands. Keep `spike/sample-java` as the integration
fixture.
