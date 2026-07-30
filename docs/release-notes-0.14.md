# Onyx 0.14

## SSH connections, rebuilt from the ground up

The headline of this release: the entire SSH transport was redesigned around a
**connection pair** — exactly two SSH connections per remote host (one active,
one warm standby), with everything Onyx does (terminals, monitoring, file
browser, git, LSP) riding them as multiplexed channels.

- **Hard cap: two TCP connections per host, ever.** No more connection storms
  hosing a remote from a flaky network; `MaxStartups` lockouts are gone by
  construction. Regression tests lock the cap in place.
- **A working connection is never torn down on suspicion — only proof.**
  Health sampling is advisory (single hiccups are logged, not acted on); only
  corroborated failures or the master process actually exiting kill a
  connection. On a stable desktop the steady state is ssh's own keepalives
  plus one no-op syscall per slot every 5s — nothing else ever fires, so the
  connection simply stays open.
- **Instant failover.** When the active connection dies, the warm standby is
  promoted and terminals reattach in ~100ms — no probe, no exponential
  backoff ladder (deleted). tmux preserves everything.
- **No dead-end states.** Connection failures never park waiting for you to
  press ⌘K. If a host is down for six hours, the moment it's back your
  terminal reattaches on its own; hard errors auto-heal when the pair rolls a
  fresh connection. Only "install your SSH key" still asks for a human.
- **The overlay can no longer lie.** One connection-state value per session,
  written only on real process events, drives the "Reconnecting" overlay, the
  status pill (hover for detail), and input gating — a dead terminal visibly
  refuses keystrokes instead of silently eating them, and a live one never
  shows "Reconnecting".
- **Network & sleep aware.** NWPathMonitor flips hosts offline the instant the
  path drops (no 45s keepalive limbo) and rebuilds immediately on restore.
  Sleep cleanly closes both masters before the network vanishes; wake rebuilds
  them before you've finished typing your password. App Nap is defeated, so
  supervision runs at full rate while you're away — repair completes before
  you sit down.
- **Polling discipline.** Every monitor/stats/git poller now skips its cycle
  while a host is down and dedups in-flight calls (per-host cap of 2) — slow
  networks no longer stack 2-3× overlapping ssh calls.
- **Airtight quit.** Quitting tears down both masters per host (bounded, 3s
  worst case), which closes every channel server-side. `ssh-leak-cleanup.sh`
  should now find nothing; it remains as forensics.

## Code navigation (LSP)
- **Java code navigation over SSH** via jdtls: go-to-definition, references,
  and **call hierarchy** from the Navigate menu, with a results panel and
  jump-to-line.
- Per-host LSP config, workspace import progress, and idle teardown.
- One-click **bootstrap/install** of jdtls on the remote, with a
  self-diagnosing preflight (robust Java detection, even when
  `JAVA_TOOL_OPTIONS` pollutes `java -version`).

## Monitor overlay
- New **3-column scrollable layout**; the Timing tile splits into bar +
  heatmap views.
- Much cheaper to keep open: poll cadence slows while hidden, chart bucketing
  is memoized, and poll ticks no longer redraw the whole app.
- Pipeline pills: the dismiss × is always visible and reliably clickable;
  duplicate GitLab pipeline rows deduped (fixed a launch crash); richer
  tooltips in simple mode.

## Flowtree
- First integration: controller client, config store, settings UI, and
  reminder submission from Onyx.

## Panels & polish
- Notes panel and file-browser panel redesigned: favorites grid on top,
  recent strip on the bottom (columns capped so titles stay readable).
- Hover/click targets now cover whole rows, not just the text.
- Terminal reliably regains keyboard focus after reload/reconnect.
- File browser: "back" no longer lands on doubled/garbage paths; opening a
  search disposes the viewed file first.
- Screensaver: totem nodes are pooled (fixes multi-GB memory growth) and
  rendering/data drivers fully stop when the screensaver does.
