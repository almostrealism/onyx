# jdtls-spike

A **throwaway** harness proving Onyx can drive the Eclipse JDT language server
(`jdtls`) over a clean byte pipe — local process or SSH — and get real semantic
Java navigation back: **subclasses, interface implementors, method overrides,
references**. It exists to retire the transport/protocol risk *before* we build
a production `LSPManager`. It links no OnyxLib types so it stays disposable.

## What it proved (run 2026-07, macOS, JDK 21, jdtls snapshot)

Against `spike/sample-java` (a 6-class inheritance graph), local transport:

| Query | Command `--symbol / --query` | Result |
|---|---|---|
| Subclasses | `AbstractShape` / `subtypes` | `Circle`, `Square` |
| Implementors | `Shape` / `implementation` | `AbstractShape`, `Circle`, `Rectangle`, `Square` |
| Overrides | `area` / `implementation` | `Circle:13`, `Rectangle:15`, `Square:13` |
| References | `area` / `references` | decl + `describe()` + `Main:15` + 3 overrides (6 total) |

Cold project import ~12s; warm queries ~4s (dominated by jdtls JVM startup per
run — the real manager keeps one server alive, so steady-state is sub-second).

## Run it

Build once: `swift build --product jdtls-spike`

**Local** (against the bundled sample; needs jdtls at `~/.onyx/jdtls/bin/jdtls`):

```sh
swift run jdtls-spike \
  --project spike/sample-java \
  --file src/main/java/com/onyx/spike/AbstractShape.java \
  --symbol AbstractShape --query subtypes
```

`--query` ∈ `subtypes | supertypes | implementation | references`.
Locate the symbol with `--symbol <name>` (auto-finds the token) or
`--line N --col N` (1-based). Add `-v` for the jdtls protocol trace.

**Remote** (the real target — same client, SSH transport, no PTY):

```sh
swift run jdtls-spike --host HOST --user USER \
  --jdtls '~/.onyx/jdtls/bin/jdtls' \
  --project /abs/remote/repo \
  --file src/main/java/.../Shape.java --symbol Shape --query implementation
```

Install jdtls on the remote first (JDK 21+ and python3 required there):

```sh
mkdir -p ~/.onyx/jdtls && \
curl -fsSL https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz \
  | tar xz -C ~/.onyx/jdtls
```

## Findings that carry into the real `LSPManager`

1. **Transport must be a raw byte pipe — no PTY.** LSP is `Content-Length`
   framed bytes; `ssh -t` would echo our stdin and translate newlines and
   corrupt the framing. Use `ssh` *without* `-t` (mirrors `sshSessionArgs`,
   minus `-t`). This is the opposite of the `RemoteScript` PTY pattern and is
   safe here because jdtls is a real `exec`, not a shell command vulnerable to
   noexec.
2. **The frame reader must tolerate leading banner noise.** A remote login
   shell may print MOTD/profile output before jdtls's first frame. The reader
   scans for `Content-Length:` rather than assuming a clean stream. (Kept in
   the spike; port it.)
3. **Server→client requests must be answered or jdtls stalls:**
   `workspace/configuration`, `client/registerCapability`,
   `window/workDoneProgress/create`. Minimal/null replies suffice.
4. **Readiness signal:** jdtls sends `language/status` notifications; `type ==
   "ServiceReady"` means the classpath is resolved. Wait for it, but keep a
   polling fallback (re-issue the query until non-empty) for robustness.
5. **First import is slow and must be async** (Maven/Gradle resolution). The
   real UI needs a non-blocking "indexing…" state driven by `$/progress`.
6. **Positions are 0-based UTF-16.** `prepareTypeHierarchy` → `typeHierarchy/
   subtypes|supertypes`; `textDocument/implementation` for implementors and
   overrides; `textDocument/references` with `includeDeclaration`.
7. **One jdtls per workspace/host**, keyed by project root; the `-data`
   workspace dir caches the import so restarts are cheaper.

## Files

- `Sources/JDTLSSpike/main.swift` — the harness (arg parsing, SSH/local
  transport, LSP client, the four queries).
- `spike/sample-java/` — minimal Maven project with a real inheritance graph.

Delete `Sources/JDTLSSpike`, the `jdtls-spike` target in `Package.swift`, and
this directory once `LSPManager` lands.
