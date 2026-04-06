# ADR-005: SSH ControlMaster path constraints (~/.onyx/, no spaces)

**Status:** Accepted
**Date:** 2026-04-05

## Context
Onyx uses SSH ControlMaster (connection multiplexing) so that multiple SSH commands against the same host share a single underlying connection. This is important for both latency and avoiding connection-rate limits on remote hosts.

Two production bugs forced the current path layout:

1. **Spaces in the socket path.** The original implementation stored mux sockets under `~/Library/Application Support/Onyx/`. The space in "Application Support" broke `ssh`'s `-o ControlPath=` argument parsing in some shell contexts. Sometimes `ssh` would interpret the path as multiple arguments, sometimes it would silently fail to find the socket and open a new connection every time. Either way, multiplexing was effectively disabled.

2. **Stale mux sockets after broken pipes.** When a network blip killed the underlying connection, the socket file remained on disk. The next `ssh` invocation would try to use it, find a half-dead master on the other end, and *hang forever* waiting for a response. No timeout, no retry, just a frozen process.

## Decision
1. All Onyx runtime files live under `~/.onyx/`:
   - SSH ControlMaster sockets
   - The MCP UNIX socket
   - The cached `OnyxMCP` binary
2. `~/.onyx/` is a path with no spaces and no shell metacharacters, safe to pass to `ssh -o ControlPath=...` without quoting gymnastics.
3. When any SSH command detects a broken pipe (or equivalent failure), it calls `markMuxStale(hostID:)`. The next `sshBaseArgs(for:)` call checks the stale flag and `unlink`s the control socket before spawning the new `ssh` process, forcing a fresh master.

## Consequences
**Good:** No path-escaping issues. Broken pipes recover automatically — the next operation against the host opens a fresh master instead of hanging. Multiplexing actually works.

**Cost:** Onyx adds one dotfile to the user's home directory. We accept this; "Application Support" is the right place philosophically but the wrong place practically.

**Pitfall:** Never, ever pass a path containing a space to `ssh`. If something needs a path that touches `ssh`, that path lives under `~/.onyx/`. If you find yourself escaping a path for `ssh`, stop and put the file under `~/.onyx/` instead.

## Alternatives considered
- **Quote/escape the ssh argument everywhere it's used.** Brittle. There are many call sites and many shell layers (LocalProcess, login shell wrappers, remote command construction). One missed escape and the bug returns.
- **Don't use ControlMaster at all.** Loses connection multiplexing entirely. Causes connection proliferation against hosts, slower command latency, and runs into per-user connection limits on some servers. Not viable.
- **Symlink `~/Library/Application Support/Onyx` → `~/.onyx`.** Inverts the problem but doesn't actually fix it; ssh still resolves the realpath in some configurations and you're back where you started.
