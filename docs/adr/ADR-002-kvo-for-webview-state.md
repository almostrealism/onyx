# ADR-002: KVO for WKWebView state instead of @Published reads during SwiftUI updates

**Status:** Accepted
**Date:** 2026-04-05

## Context
The first implementation of the browser panel exposed `@Published` properties on `BrowserManager` (`currentURL`, `canGoBack`, `canGoForward`, `isLoading`, `title`). `BrowserHostView` (an `NSViewRepresentable`) read these properties inside `updateNSView` to drive its toolbar state.

This caused the app to hang. It took three diagnostic passes to figure out why.

The problem: reading a `@Published` property inside `updateNSView` causes SwiftUI to register a dependency. The same `updateNSView` then called `BrowserManager.activate(session:)` to make sure the right web view was attached. `activate()` wrote to those same `@Published` properties (because activating a session updates the visible URL, etc.). That write invalidated the dependency SwiftUI had just registered, which scheduled another `updateNSView`, which ran `activate()`, which wrote, which invalidated… infinite re-entry, main thread pegged.

## Decision
1. `BrowserManager` does **not** expose web view state via reads-during-update. Instead it sets up KVO observations on the underlying `WKWebView`'s own properties: `url`, `title`, `isLoading`, `canGoBack`, `canGoForward`. KVO callbacks dispatch to main and then update the `@Published` mirror.
2. `activate(session:)` is **never** called from inside `updateNSView`. If activation is needed, `updateNSView` schedules it via `DispatchQueue.main.async { ... }` so the call happens after the current update cycle completes.
3. `BrowserHostView.Coordinator` tracks the currently-active session ID, so redundant `activate()` calls (which would still write to `@Published` properties) are skipped entirely.

## Consequences
**Good:** Browser state stays reactive, the toolbar updates correctly, and there is no re-entry. KVO is the source of truth; SwiftUI only ever observes the mirror.

**General rule extracted:** Do not write to `@Published` properties from inside an `NSViewRepresentable.updateNSView` (or `updateUIView`) call. If you need to mutate observable state in response to an update, defer it with `DispatchQueue.main.async`.

**Pitfall:** Any new `NSViewRepresentable` wrapping a stateful AppKit component is likely to fall into the same trap. Future representable wrappers should follow the same pattern: KVO/delegate → async dispatch → `@Published`.

## Alternatives considered
- **Read-only computed properties backed by the web view.** Solves the write half but introduces timing problems: the values you read may not be the values SwiftUI thinks it depends on, leading to stale toolbars.
- **Separate observation object that the view reads.** Same re-entry risk if any code path writes to it during an update. Doesn't structurally prevent the problem.
- **Move activation entirely out of `updateNSView`.** We do this now (via the async dispatch and the Coordinator's session tracking), but on its own it isn't enough — you also need the property reads to come from KVO so that the dependency graph is honest about what changes when.
