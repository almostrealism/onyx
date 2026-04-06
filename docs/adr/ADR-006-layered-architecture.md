# ADR-006: Layered architecture with strict downward dependencies

**Status:** Accepted
**Date:** 2026-04-05

## Context
Onyx grew organically to roughly 14k lines across 26 files. Manager classes, SwiftUI views, models, and persistence helpers were all mixed together in the same files. Symptoms:

- Hard to find where a piece of behavior lived. Was reconnect logic in the view, the manager, or AppState? All three, partially.
- Easy to introduce circular dependencies between managers (Manager A reaches into Manager B which reaches back).
- Adding a new feature meant guessing which existing file to extend and often guessing wrong.
- Code review couldn't tell whether a change was a presentation tweak or a behavior change because both lived next to each other.

The codebase was past the size where "just put it where it fits" works.

## Decision
Reorganize the source tree into 6 strict layers. Each layer may only depend on layers below it:

1. **Models** — pure data types, no behavior beyond `Codable` and trivial computed properties.
2. **Services / Stores** — single-purpose stateful holders (e.g. `NetworkTopologyStore`), persistence, and side-effect-free helpers.
3. **Managers** — long-lived coordinators that own behavior (e.g. `TerminalSessionManager`, `MonitorManager`, `BrowserManager`).
4. **App** — `AppState`, `AppDelegate`, `OnyxApp`. The wiring layer.
5. **Views** — SwiftUI views. Presentation only.

Additional rules:
- Managers may not call other Managers directly. They communicate through Stores or through `AppState`.
- Views contain no business logic. If a view is doing more than formatting and dispatching user input, the logic belongs in a Manager.
- Models depend on nothing. Stores depend only on Models. And so on up the stack.

The full ruleset, including naming conventions and the "Store vs Manager" decision criteria, lives in `CLAUDE.md`.

## Consequences
**Good:** Clearer home for new code. The first design question for any feature becomes "is this state, a service, a coordinator, or presentation?" — which is the right question. Smaller average file size. Easier code review.

**Cost:** Enforced by convention, not by the build system. Nothing stops a future change from importing across layers the wrong way; only review catches it.

**Pitfall:** The most common violation is a view reaching into a Store directly to do "just one quick thing." Resist. If the view needs the data, a Manager should expose it.

**Open question:** Whether to add a lint or build-phase check that enforces layer boundaries. For now we rely on convention and CLAUDE.md.

## Alternatives considered
- **Feature-based folders** (everything for "browser" in one folder, everything for "monitor" in another). Reads nicely but obscures the dependency structure — you can't tell at a glance whether code is a view, a manager, or a store, and cross-feature shared code becomes homeless.
- **Flat layout.** What we had. Doesn't scale past a few thousand lines.
- **Strict module separation via SPM targets.** Would mechanically enforce the boundaries but adds significant build-time and tooling friction for a single-binary app. Worth revisiting if the codebase doubles again.
