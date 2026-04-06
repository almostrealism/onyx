# ADR-004: Per-host state isolation for monitoring, reconnection, and errors

**Status:** Accepted
**Date:** 2026-04-05

## Context
Several manager classes started life with single-host assumptions and broke in interesting ways once Onyx routinely had multiple hosts active:

- **MonitorManager** had one global `samples` array. Switching hosts polluted the CPU/memory charts with data from the previous host. The chart literally lied about which machine you were looking at.
- **AppState** had a global `isReconnecting` flag. When *any* host was reconnecting, the reconnect overlay appeared on *every* session — including healthy ones on other hosts.
- SSH stderr from one host's monitoring script would set a global "SSH failed" flag, and every session in the UI would show the connection error banner.

The common bug was treating per-host state as global state.

## Decision
Every piece of state that conceptually belongs to a specific host must be keyed by `hostID: UUID`.

Concretely:
- `MonitorManager` stores `[UUID: HostMonitorData]` and exposes computed accessors that resolve against the currently-active host. Background polling for non-active hosts keeps writing into their own buckets.
- `AppState` has `reconnectingHostID: UUID?` and `connectionErrorHostID: UUID?` (instead of booleans), with computed convenience properties `isActiveSessionReconnecting` and `activeSessionHasError` for views.
- `MonitorManager` distinguishes SSH transport failure (exit code 255) from script failure (any other non-zero exit). A failing stats script does not raise a connection error; only an actual SSH failure does.

**The rule:** Before adding a `@Published` variable to a Manager, ask "is this per-host?" If yes, key it by `hostID`. If you can't decide, it's per-host.

## Consequences
**Good:** The UI is honest. The reconnect overlay only appears on the session it belongs to. Charts show the host you're looking at. Background polling for inactive hosts works without contaminating the foreground view.

**Cost:** Slightly more verbose state management. Every read goes through a dictionary lookup or a computed accessor. Worth it.

**Pitfall:** It's easy to add a new `@Published var somethingHappened: Bool` to a manager without thinking about which host it belongs to. Code review should flag this every time.

## Alternatives considered
- **Separate Manager instance per host.** Cleanest in theory but requires a lot of wiring: lifecycle management, factory plumbing, view-side selection, persistence per instance. Too much ceremony for the gain.
- **Single Manager with active-host-only view.** Simpler, but loses background polling — you'd only have data for the host you were currently looking at, and switching back to a host would show a flat chart until new samples arrived.
