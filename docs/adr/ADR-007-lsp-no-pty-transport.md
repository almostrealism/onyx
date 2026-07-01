# ADR-007: LSP servers run over a no-PTY byte pipe

**Status:** Accepted
**Date:** 2026-07-01

## Context
The code-navigation feature drives the Eclipse JDT language server (`jdtls`) on
the remote host over SSH. LSP is a JSON-RPC protocol framed with a
`Content-Length:` header and a `\r\n\r\n` separator — an exact, byte-precise
binary stream in both directions.

Onyx already has two well-worn SSH invocation patterns, and both are wrong here:

1. **`RemoteScript` (interactive `ssh -tt`, script via stdin).** The noexec-safe
   pattern for *data reads* (see ADR on remote execution / CLAUDE.md). It
   allocates a PTY and feeds a script over stdin. A PTY's line discipline
   **echoes stdin back** and **translates newlines** (`\n` ⇄ `\r\n`). Fed an LSP
   stream, the framing is corrupted: our own writes echo back into the read
   channel and byte counts stop matching `Content-Length`.

2. **`sshCommand` / `dockerTmuxCommand` (interactive `ssh -t`).** Correct for
   tmux and `docker exec -it`, which *are* terminals. Same PTY problem for LSP.

The naive move — copy `sshCommand` for the LSP launcher and keep `-t` — was
explicitly tried in the exploration phase and would silently corrupt every
message. It is the obvious mistake.

## Decision
The language-server launcher (`AppState.remoteLSPCommand`) opens a **clean byte
pipe with no PTY**:

- Built on `sshSessionArgs` (a long-lived, independent, non-multiplexed SSH
  session, like a terminal) **minus `-t`**. No pseudo-terminal is allocated, so
  stdin isn't echoed and newlines aren't translated — stdout is exactly the
  server's bytes.
- **No MCP port forwarding** (that's a tmux-session concern, irrelevant here).
- The frame reader (`LSPProtocol.decode`) is **banner-tolerant**: a remote login
  shell may print an MOTD before the server's first frame, so the decoder scans
  for `Content-Length:` rather than assuming a pristine stream.

Crucially, this is **safe from the noexec trap** even though it passes a command
to `ssh`. The noexec danger is a hostile *login shell* refusing to run a
script argument. Here the command `exec $SHELL -lc '… jdtls …'` ends in a real
`exec` of the jdtls binary; a shell that can't exec a program can't run the
feature at all, so there's nothing to protect against — and jdtls itself is not
a shell script we need the remote shell to interpret line by line.

A regression test (`AppStateTests.testRemoteLSPCommand_*`) asserts the launch
command contains **neither `-t` nor `-tt`**, so a future refactor can't quietly
"fix" it back into a PTY.

## Consequences
**Good:** LSP framing is byte-exact and reliable. The same client speaks to any
LSP server (Java today, others later) with no transport changes. Validated
end-to-end against real `jdtls` both locally and over SSH (loopback).

**Cost:** We now have *three* SSH patterns, not two, and the LSP one is the odd
one out (no `-t`). This ADR and the test exist so that's a documented, enforced
decision rather than a trap.

**Pitfall:** Never add `-t`/`-tt` to `remoteLSPCommand`, and never route an LSP
stream through `RemoteScript`. If a language server "connects but returns
garbage / never responds," the first thing to check is whether a PTY snuck into
the transport.

## Alternatives considered
- **Reuse `RemoteScript` (`ssh -tt` + stdin).** Corrupts framing via PTY echo
  and newline translation. This is the pattern for *data reads*, not for a
  persistent binary protocol.
- **`jdtls` socket mode + SSH port-forward.** Launch jdtls listening on a TCP
  port on the remote and tunnel it. Viable and sometimes cleaner, but adds port
  management and a second failure surface; the stdio pipe is simpler and was
  proven sufficient in the spike. Kept in reserve if stdio muxing ever bites.
- **Run jdtls locally against synced files.** Would fight path translation and
  file-sync drift forever; the code lives remotely, so the server runs remotely
  and sees native remote paths.
