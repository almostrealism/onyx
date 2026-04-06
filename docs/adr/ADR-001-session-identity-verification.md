# ADR-001: Session identity verification at async boundaries

**Status:** Accepted
**Date:** 2026-04-05

## Context
Onyx had a recurring class of bugs around session reconnection that took several attempts to fully diagnose:

- The user would switch sessions during a reconnect delay and the view would suddenly jump back to the old session.
- The reconnect overlay would appear on the wrong session.
- Health checks would mark the active session as failed when actually a previously-active session had died.

The root cause was always the same shape: a `DispatchQueue.main.async` or `asyncAfter` block captured a session ID (or worse, a reference) at the time of scheduling, and then when the block ran later it acted on that captured value without checking whether the user had since moved to a different session.

This is a classic stale-closure problem, made worse by the fact that reconnect logic is inherently delay-driven (backoff timers, health check intervals, process termination callbacks). The window between "decide to act" and "act" is exactly where the user is most likely to switch sessions.

## Decision
At every async boundary in session-related code, the block must re-verify that `appState.activeSession?.id` still matches the captured session ID before taking any action that affects the active session UI (overlays, status, view swaps).

The pattern:

```swift
let sessionID = session.id
DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
    guard let self = self else { return }
    guard self.appState.activeSession?.id == sessionID else { return }
    // safe to act
}
```

Sites where this pattern was applied (and must remain):
- `TerminalSessionManager.healthCheck()`
- `TerminalSessionManager.performReconnect()`
- `TerminalSessionManager.reconnect()`
- `TerminalSessionManager.processTerminated()`

## Consequences
**Good:** Massive reduction in race conditions around reconnect. The reconnect overlay now reliably belongs to the session it describes.

**Cost:** A few extra lines per async block. Easy to forget on new code paths.

**Pitfall:** If you add a new async callback in session-management code without the guard, the bugs come back. The pattern must be followed consistently. Reviewers should treat any new `DispatchQueue.main.async` in `TerminalSessionManager` (or similar) as suspect until they see the identity check.

## Alternatives considered
- **Actor isolation.** Would solve this structurally but requires migrating significant chunks of the codebase to Swift Concurrency. Too invasive for the current state.
- **Cancellation tokens.** Same migration cost; also adds bookkeeping for every scheduled work item.
- **Single-threaded session mutation queue.** Would serialize too much unrelated work and doesn't actually fix the stale-capture problem — a queued action against an old session is still wrong, just ordered.
- **Capture the session reference (not ID) and compare by identity.** Doesn't help, because the user may have legitimately re-selected the same session and we'd still want to bail on the old in-flight reconnect.
