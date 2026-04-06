# Plan: Integration Tests + Public API Documentation Pass

**Status:** Proposed
**Date:** 2026-04-05
**Relates to:** audit of test coverage and documentation after the layered
architecture restructure. Items #5 and #6 from that audit are tracked here.

## Context

After the Models → Services/Stores → Managers → App → Views restructure,
we now have:

- 309 unit tests split across per-layer test files mirroring `Sources/OnyxLib/`
- Regression tests for the load-bearing bug categories (Timing parsing,
  per-host MonitorManager isolation, SSH mux path + stale cleanup,
  BrowserManager KVO activation)
- 6 ADRs capturing the *why* behind reconnection identity verification,
  KVO for WKWebView, topology grace periods, per-host isolation, mux
  path constraints, and the layered architecture
- File-level headers on all 10 Managers and 4 Stores
- `CLAUDE.md` at the project root with the layer diagram

Two gaps remain from the original audit:

1. **No end-to-end / integration tests.** Every existing test is a pure
   unit test of a parser, model, or in-memory manager. We have no tests
   that exercise the real wire format of OnyxMCP, the dashboard HTTP
   endpoints, or the SSH command construction → process launch → output
   round trip.

2. **Only ~45% of public APIs have doc comments** (31 `///` doc lines
   across 68 public declarations in OnyxLib). Several Managers have zero
   symbol-level docs even after the file-level headers were added.

This document proposes concrete plans for both.

---

## Part 1: Integration smoke tests

### Goal

One focused integration test suite that catches regressions in the wire
formats and process boundaries that unit tests can't see.

### What we actually need to test

| Area | Unit test coverage | Integration gap | Risk |
|---|---|---|---|
| MCP tool registration & JSON-RPC | good (parser, handler) | real stdio round-trip from a live OnyxMCP binary | framing / encoding regressions |
| Dashboard HTTP endpoints | **zero** | can an HTTP client hit the routes and get expected JSON? | silent breakage on refactor |
| SSH command construction | good (args) | `Process` actually launches with those args and ssh rejects/accepts them syntactically | ssh option typos slip through |
| Claude hook JSON format | parser tested | real `OnyxMCP --hook <event>` invocation matches what Claude actually sends | format drift on Claude upgrades |
| Topology store persistence | unit tested | does the on-disk JSON round-trip across a real app launch? | schema drift on model changes |

### Proposed structure

Create a new test target `OnyxIntegrationTests` in `Package.swift`:

```swift
.testTarget(
    name: "OnyxIntegrationTests",
    dependencies: ["OnyxLib", "OnyxMCP"],
    path: "Tests/OnyxIntegrationTests"
)
```

Separate from `OnyxTests` because:
- Integration tests are slower and may be flaky on CI
- They need access to the OnyxMCP executable as a build product
- We want to be able to run `swift test --filter OnyxTests` for the fast loop

### Concrete tests to write

**1. MCP stdio round-trip** (`MCPStdioTests.swift`)
- Launch OnyxMCP as a subprocess with stdin/stdout piped
- Send `initialize` → expect response with protocol version and server info
- Send `tools/list` → expect the current tool set (`show_text`, `show_diagram`, `show_model`, `clear_slot`, `list_slots`)
- Send `tools/call` with an unknown tool → expect a well-formed error response
- Send a notification (no id) → expect no response
- Close stdin → expect clean exit

**2. OnyxMCP hook mode** (`HookModeTests.swift`)
- Invoke `OnyxMCP --hook PreToolUse` with a JSON payload on stdin
- Verify exit code 0 and expected output shape
- Test each hook event type that Claude emits
- Test malformed payload → non-zero exit with diagnostic

**3. Dashboard HTTP smoke** (`DashboardServerTests.swift`)
- Start `DashboardServer` on a random port
- GET every registered route
- Assert status codes, content types, and basic JSON shape
- Verify the server stops cleanly

**4. SSH argument syntactic check** (`SSHArgsSyntaxTests.swift`)
- For each `sshBaseArgs` / `sshSessionArgs` / `scpBaseArgs` output, invoke
  `ssh -G <host> <args>` (dry-run) or `ssh -o <option>=<value> -T
  /bin/false` to verify ssh doesn't reject the option syntax. This catches
  typos in option names before they cause runtime hangs.

**5. NetworkTopologyStore persistence round-trip** (`TopologyPersistenceTests.swift`)
- Create a store with a fixed temp URL
- Populate it with entries across multiple hosts and probe results
- Write to disk
- Create a fresh store pointing at the same URL
- Assert the loaded state matches

### Out of scope

- No real SSH connections to real hosts (too flaky, needs credentials)
- No SwiftTerm / tmux process interaction (the terminal lifecycle is
  already guarded by session identity unit tests; a true integration
  test would need a real tmux server)
- No UI integration tests (SwiftUI snapshot tests are a separate, larger
  investment — see future plan)

### Rollout

1. Add the test target in a single commit that also adds the first test
   (MCP stdio round-trip). Verify it runs under `swift test`.
2. Add the remaining test files one at a time, each in its own commit.
3. Add a GitHub Actions workflow (or note for the user to add one) that
   runs `swift test` on every push. Separate the fast (`OnyxTests`) and
   slow (`OnyxIntegrationTests`) runs so developers can opt out locally.

### Expected outcome

Target: ~30-50 additional tests. Runtime: <10 seconds total (each
subprocess launch is ~100ms, HTTP tests are near-instant).

---

## Part 2: Public API documentation pass

### Goal

Every `public` symbol in OnyxLib has a `///` doc comment explaining what
it does, what its invariants are, and (where non-obvious) who calls it.

### Current state

- 68 public declarations in OnyxLib
- 31 `///` doc comment lines total (many symbols have zero, some have
  multi-line docs that inflate the count)
- File-level headers (added in this round) cover *responsibility* for
  each Manager/Store, but individual methods are often undocumented
- `TerminalSessionManager` is the bright spot — the reconnection safety
  work left comprehensive method docs. Other Managers should match.

### What "documented" means for this pass

Each public symbol gets a `///` block containing at minimum:

1. **What** — one-sentence summary in imperative mood
2. **When to call** — if non-obvious (e.g. "from `updateNSView` only")
3. **Thread expectations** — if the method has any (main-only, background-safe, etc.)
4. **Invariants / side effects** — what state it mutates, what ordering matters
5. **Returns / throws** — for non-trivial returns

Example:

```swift
/// Mark a host's SSH ControlMaster as stale. The next call to
/// `sshBaseArgs(for:)` for this host will delete the existing socket
/// file before spawning a new command. Used after SSH exit code 255
/// (broken pipe) to avoid hanging on a dead master.
///
/// Thread-safe to call from any queue (main recommended; the flag is
/// consumed atomically within `sshBaseArgs`).
///
/// - Parameter hostID: The host whose mux socket should be cleaned up.
public func markMuxStale(for hostID: UUID) { ... }
```

### Execution plan

Do one Manager/Store file per commit so each is a small, reviewable diff.
Priority order (most-public-facing first):

1. `AppState` — central orchestration, most-referenced type
2. `TerminalSessionManager` — already partially documented, fill gaps
3. `MonitorManager`, `BrowserManager`, `FileBrowserManager` — per-window managers
4. `GitManager`, `DockerStatsManager`, `TimingManager`, `ClaudeSessionManager`
5. `ArtifactManager`, `NotesManager`
6. `NetworkTopologyStore`, `FavoritesStore`, `AppearanceStore`, `TimingDataStore`
7. `MCPServer`, `DashboardServer` — services
8. `SessionModels`, `HostConfig`, `ConnectionModels`, etc. — models
   (often self-explanatory but still merit one-line summaries)

For each file:
- Read the file
- Identify every `public` declaration
- Add `///` comments following the template above
- Do NOT rename or restructure anything
- Run `swift build` to verify
- Commit with a scoped message like "Document MonitorManager public API"

### Definition of done

- Every public declaration in `Sources/OnyxLib/` has a `///` block
- Running `grep -c "^public\|^    public" Sources/OnyxLib/**/*.swift`
  and comparing to `grep -c "^///\|^    ///"` shows roughly 1:1 ratio
  (some public symbols are trivially documented by their signature,
  like `public var id: UUID`, and those are fine)
- No behavior changes (tests still pass, nothing is renamed)
- Optional: add a SwiftLint or swift-doc coverage check to CI

### Expected outcome

~40-50 additional doc blocks across ~20 files. No runtime impact. Makes
new-developer ramp-up dramatically faster and makes Claude sessions
more reliable since the doc comments are included in context.

---

## Suggested order of execution

If the user green-lights both parts:

1. Part 1, step 1 (add test target + MCP stdio test) — one commit
2. Part 1, steps 2-5 (each integration test) — commit per test
3. Part 2, file by file — commit per file

Total: ~25-30 small commits. Each builds and tests cleanly. Low risk,
high long-term durability value.

## Open questions

- **CI setup**: Does this project have GitHub Actions yet? If not, the
  integration test value drops significantly — the whole point is
  automatic regression detection, not "run it locally before you remember."
- **OnyxMCP Linux build in CI**: Part 1 #1 and #2 require the OnyxMCP
  binary. A macOS CI job can build it directly; a Linux job would need
  the existing Docker build path.
- **SwiftLint / swift-doc**: Would the user accept a small CI step that
  fails the build on undocumented public APIs? That's the only way
  Part 2 stays complete long-term.
