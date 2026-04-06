# ADR-003: Topology grace periods instead of enumeration list replacement

**Status:** Accepted
**Date:** 2026-04-05

## Context
Docker container sessions (and to a lesser extent SSH host sessions) kept disappearing from the session list as the app ran. The pattern was: everything is fine for a while, then a flicker, then half the containers are gone. They'd come back on the next poll, but in the meantime the user's open session would have been marked unavailable.

The cause was straightforward: `enumerateAllSessions` did a full replacement of `allSessions`. A single failed `docker ps` invocation — or one SSH timeout, or one host with a transient network blip — would yield zero containers for that host on that pass, and the replacement would wipe every container session for that host from the list. Sometimes the failure cascaded across hosts and wiped almost everything.

The deeper issue is that enumeration is *probing*, not *truth*. A failed probe should not be treated as evidence of absence.

## Decision
Introduce `NetworkTopologyStore` as a singleton source of truth for session existence over time.

Key elements:
- `enumerateHostSessions` returns a tuple `(sessions, probeResult)` where `probeResult` distinguishes "host unreachable", "host reachable, listed N sessions", and "host reachable, listing failed."
- The store merges new probe results into existing entries instead of replacing:
  - Sessions seen in this probe are marked alive with `lastSeen = now`.
  - Sessions previously known but missing in this probe transition to dead **only after a 30-second grace period**.
  - If the host is unreachable, the store does not touch any of that host's entries at all.
- Recently-dead sessions (< 10 minutes since last seen) still surface in the UI as `unavailable: true` so the user can see "this was here a minute ago" rather than the row vanishing.
- The store persists to disk and garbage-collects entries older than 24 hours on launch.

## Consequences
**Good:** Sessions survive transient network failures, slow `docker ps`, brief SSH hiccups. The UI is stable enough to actually use against flaky networks.

**Cost:** The list the UI shows is slightly more complex to derive — it's not "the latest probe result" but "the merged topology view." There's also a small persistence cost.

**Pitfall:** Do not, under any circumstances, revert to "wipe and replace" enumeration. Anyone touching enumeration code should preserve the merge semantics. If a probe fails, the store must be told *that the probe failed*, not handed an empty list.

## Alternatives considered
- **Retry-on-failure inside the enumerator.** Helps with transient command failures but doesn't help with long timeouts (the probe just takes longer to fail and then still wipes everything).
- **Longer polling interval.** Reduces frequency of the bug but doesn't fix it; the first time a probe fails, sessions still vanish.
- **Treat every probe as authoritative but debounce UI.** Hides the symptom briefly but loses session identity across the gap, so reconnect targets get confused.
