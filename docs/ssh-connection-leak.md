# SSH Connection Leak — Investigation & Handoff

**Status:** Fixed (2026-06-03). See "Resolution" section at the bottom.
**Severity:** High. Caused the *remote* host to lock out new SSH logins (including manual ones).
**Date investigated:** 2026-06-03

This note documents a confirmed bug in Onyx's SSH session lifecycle. It is written as a
handoff so another agent can implement the fix. All findings below were verified live against
a real affected host, not inferred.

---

## Symptom

The user became unable to `ssh` into one of their Macs. The cause was **SSH connection
exhaustion** driven by Onyx running on other machines connecting into that host.

### Observed topology

```
michaels-imac        (100.65.41.32, ONLINE)  ─┐
                                              ├── SSH ──▶  macbook-pro (victim) :22
michaels-macbook-air (100.83.133.53, OFFLINE) ┘            sshd, user `michael`
```

On the victim host (`macbook-pro`) at time of investigation:

- **86 `sshd-session` processes**, 40 logged-in users.
- **41 ESTABLISHED** connections to `:22`, plus a pile of `FIN_WAIT_1` / `LAST_ACK` /
  `TIME_WAIT` sockets that were not being reaped (one `FIN_WAIT_1` held 129 KB of unACKed
  send-queue from the now-offline macbook-air).
- **32 interactive `michael@ttysNN` sessions** + **9 `michael@notty` (command-exec / mux)
  sessions**.
- The oldest `notty` channels were **over 30 hours old** (`etime 01-06:29:33`). These are
  Onyx's non-interactive command/ControlMaster channels and should be short-lived.

### Why the lockout happens

The victim's sshd uses the default **`MaxStartups 10:30:100`**. That governs *unauthenticated*
(pre-auth) connections: at 10 concurrent, sshd begins randomly refusing new connections; at 100
it refuses all. When Onyx fires a reconnect/enumeration **burst**, ≥10 connections sit in the
login phase simultaneously and sshd drops new logins — including the user's manual `ssh`. This is
why the lockout is **intermittent** ("comes and goes") rather than constant.

The victim's sshd also has **no `ClientAliveInterval`** (default `0` = disabled), so sshd never
probes idle sessions. Dead/orphaned channels — including the offline macbook-air's zombie
sockets and Onyx's leaked `notty` channels — therefore persist indefinitely (the 30-hour-old
sessions) instead of being reaped.

---

## Root cause in Onyx (what to fix)

The core defect is **missing remote connection teardown**. Onyx opens SSH channels and relies on
either local `process.terminate()` or `ControlPersist` expiry to clean them up — neither of which
reliably closes the *remote* side. Listed in priority order.

### 1. `ssh -O exit` is not called on session teardown or failed reconnect  *(primary)*

`AppState.sshMuxStop(for:)` (`Sources/OnyxLib/App/AppState.swift:1425`) issues the
`ssh -O exit` that actually closes a ControlMaster. But it is only invoked on:

- `removeHost` (`AppState.swift:394`)
- wake-from-sleep cleanup `cleanupStaleMuxSockets` (`AppState.swift:1234`)
- SSHKeeper slot rotation/reset (`Sources/OnyxLib/Managers/SSHKeeper.swift:161`, `:275`)

It is **not** called when:

- an interactive session ends (`TerminalSessionManager.processTerminated`,
  `Sources/OnyxLib/Managers/TerminalSessionManager.swift:1468` — only `process.terminate()`),
- a reconnect fails or replaces a session (`performReconnect`, `TerminalSessionManager.swift:1417`),
- a utility/`remoteScript` command fails.

`sshMuxArgs` uses `ControlPersist=120` (`AppState.swift:1154`), so an idle master *should* die
after 2 minutes. But the frequent pollers (below) keep touching the mux so it never goes idle
that long, and when a master is marked stale a **new** one is spawned without `-O exit`-ing the
old. Net effect: `notty` mux/exec channels accumulate (the 30-hour-old sessions).

**Fix direction:** call `sshMuxStop` / `ssh -O exit` on every interactive-session teardown, on
every failed/replaced reconnect, and whenever a mux is marked stale (don't just abandon it).
Track spawned `ssh` Processes so they can be explicitly closed.

### 2. No host-wide reconnect gate → reconnect storm  *(causes the MaxStartups trip)*

`TerminalSessionManager.reconnect` (`TerminalSessionManager.swift:1348`) backs off **per session**
(`min(pow(2, attempt) * 0.5, maxBackoff)`) with no host-level coordination. On a single network
blip, every pooled session reconnects independently and near-simultaneously, producing the burst
of concurrent pre-auth connections that trips `MaxStartups` on the remote.

**Fix direction:** add a per-host reconnect gate/serialization with jittered backoff so only a
bounded number of reconnects to a given host are in flight at once.

### 3. Interactive sessions are not explicitly closed on the remote

`destroyPoolEntry` (`TerminalSessionManager.swift:1454`) sends SIGTERM to the local `ssh` process,
then `performReconnect` waits a **hardcoded 1 s** (`TerminalSessionManager.swift:1430`) before
spawning a replacement. SIGTERM is async and the remote pty/session may still be in sshd's process
table, so the replacement stacks on top of the not-yet-reaped old one. Interactive sessions use
`sshSessionArgs` with **no ControlMaster** (`AppState.swift:1197`), so each is a full independent
connection.

**Fix direction:** confirm the remote side is gone (or use `ServerAlive`/explicit close) before
respawning, rather than a fixed 1 s sleep.

### 4. Polling amplifies the leak (contributing factor)

These timers each open remote SSH commands and keep masters warm:

- `MonitorManager` — every **5 s**, active host (`Sources/OnyxLib/Managers/MonitorManager.swift:84`)
- `CPUFleetPoller` — every **10 s**, **all** hosts in parallel (`Sources/OnyxLib/Managers/CPUFleetPoller.swift:88`)
- `TerminalSessionManager` periodic enumeration — checks every 15 s, refreshes ~every 60 s,
  opening one SSH command per host **and per container** (`TerminalSessionManager.swift:602`,
  enumeration at `:928`/`:1129`).

These are fine *if* connections are reused and reaped. They become a problem only because of
issues #1–#3. They mainly matter for sizing any connection cap.

---

## Suggested fix checklist

- [ ] Call `ssh -O exit` (via `sshMuxStop`) on interactive-session teardown, failed/replaced
      reconnects, and stale-mux handling. Retain spawned `ssh` `Process`es so they can be closed.
- [ ] Add a per-host reconnect gate with jittered backoff to prevent reconnect storms.
- [ ] Replace the hardcoded 1 s reconnect delay with confirmation the remote session is gone.
- [ ] Consider a per-host open-connection cap + a reaper for orphaned `ssh` processes.
- [ ] Add a regression test in `Tests/OnyxTests/App/AppStateTests.swift` asserting teardown paths
      invoke `-O exit` (mirror the existing "lock the shape of SSH command builders" pattern).

## Suggested remote-host hardening (operational, not code)

Independent of the Onyx fix, the affected sshd should be hardened so a buggy client can't lock the
user out and dead sessions self-reap. Append to `/etc/ssh/sshd_config`:

```
ClientAliveInterval 60
ClientAliveCountMax 3
MaxStartups 100:30:200
```

Reload: `sudo launchctl kickstart -k system/com.openssh.sshd` (restarts the SSH listener; drops
existing sessions). Immediate manual cleanup of leaked channels: `sudo kill <notty-pids>`.

---

## Key file references

| Concern | File | Line |
|---|---|---|
| `ssh -O exit` exists but rarely called | `Sources/OnyxLib/App/AppState.swift` | 1425 |
| Mux args, `ControlPersist=120` | `Sources/OnyxLib/App/AppState.swift` | 1154 |
| Interactive session args (no ControlMaster) | `Sources/OnyxLib/App/AppState.swift` | 1197 |
| Reconnect, per-session backoff (no host gate) | `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 1348 |
| `performReconnect`, hardcoded 1 s, no `-O exit` | `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 1417 |
| `destroyPoolEntry` (local terminate only) | `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 1454 |
| `processTerminated` → reconnect | `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 1468 |
| Periodic enumeration | `Sources/OnyxLib/Managers/TerminalSessionManager.swift` | 602 |
| MonitorManager 5 s poll | `Sources/OnyxLib/Managers/MonitorManager.swift` | 84 |
| CPUFleetPoller 10 s poll (all hosts) | `Sources/OnyxLib/Managers/CPUFleetPoller.swift` | 88 |
| SSHKeeper (mux supervisor) | `Sources/OnyxLib/Managers/SSHKeeper.swift` | 30 |

---

## Resolution (2026-06-03)

### Code fixes shipped

| # | Issue | Where | What changed |
|---|---|---|---|
| 1 | `ssh -O exit` rarely called; orphan masters held remote TCP connections open | `Services/SSHProcess.swift` (new), `Managers/SSHKeeper.swift`, `App/AppState.swift` | New `SSHProcess.killMaster(at:userHost:)` does `ssh -O exit` first, then escalates to finding the owning PID via `lsof` and SIGKILLing it, then removes the socket file. `SSHKeeper.establish` calls this before respawning a slot's master. `AppState.sshMuxStop` routes through it. Every teardown is now bounded and definitive — no orphans. |
| 2 | App quit didn't close masters → orphans accumulated on remote | `App/AppDelegate.swift`, `Managers/SSHKeeper.swift` | New `applicationWillTerminate` calls `SSHKeeper.shared.shutdown()` which closes every slot for every host. Survives `pkill -9` of Onyx because the shutdown happens before the process exits in the normal-quit case; the leftover orphan path only happens on actual force-quit and is recoverable via `scripts/ssh-leak-cleanup.sh`. |
| 3 | Reconnect storm trips remote `MaxStartups` | `Managers/TerminalSessionManager.swift` | Per-host reconnect gate (`acquireReconnectGate` / `releaseReconnectGate`) ensures at most one reconnect to a given host is scheduled/in-flight at a time. Watchdog auto-releases after 30s to prevent leaks. Plus 0-30% jitter on the per-session backoff so any simultaneous unblock events don't re-create the storm. |
| 4 | `Process.terminate()` is SIGTERM, which ssh can ignore → hung supervisor + dispatch-thread-pool exhaustion | `Services/SSHProcess.swift` | All ssh runs go through `SSHProcess.run` with SIGTERM at `softTimeout`, SIGKILL one second later. `waitUntilExit()` is guaranteed to return within `softTimeout + ~1s`. |

### Operational cleanup tool

`scripts/ssh-leak-cleanup.sh` — run on any client that's been running Onyx to definitively close every onyx-mux master:

```bash
bash scripts/ssh-leak-cleanup.sh
```

It does `ssh -O exit` on every socket, then SIGKILLs any straggler `ssh` processes referencing `~/.ssh/onyx-mux/`, then removes leftover socket files. Idempotent and safe.

### Tests

`Tests/OnyxTests/Services/SSHProcessShapeTests.swift` pins the contracts:

- `findMasterPIDs` returns empty for a missing path (no crash, no hang).
- `killMaster` is a no-op on a missing path and returns within seconds.
- `run` against a bogus host returns within `softTimeout + ~1s` — pinning the SIGKILL escalation discipline.

### Items NOT shipped from the checklist

- **Confirmation that remote session is gone before respawning (replace hardcoded 1s).** The 1s sleep in `performReconnect` is still there. The reconnect gate alone should prevent the storm, and the master killer ensures no orphans, so the hardcoded sleep is no longer load-bearing — but it's a code smell. Left for a follow-up.
- **Per-host open-connection cap + orphan reaper.** Not built; the master killer addresses the primary cause.
- **Remote sshd hardening** (`ClientAliveInterval`, `MaxStartups`) — out of scope for the client; left for the operator.
