# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Onyx.

## What is an ADR?
An ADR is a short document capturing a single load-bearing design decision: the context that forced the decision, what we chose, the consequences (good and bad), and the alternatives we considered and rejected.

The point of an ADR is **to preserve the WHY**. Code shows what the system does today; an ADR explains why it does it that way and what will break if you undo it. They exist primarily so that future developers — and future Claude sessions — don't accidentally re-introduce a bug class that was already solved.

## When to write a new ADR
Write one when:
- You make a decision that constrains future code (e.g. "all X must Y").
- You fix a bug whose root cause was a structural assumption, and the fix is a pattern other code must also follow.
- You pick between two plausible designs and want the rejected option's reasoning preserved.
- Reverting the decision would silently re-introduce a real bug.

You do **not** need an ADR for routine implementation choices, naming, refactors, or anything that future code can freely change without consequence.

## Format
Copy the structure from any existing ADR. Number sequentially. Status starts as `Proposed` and moves to `Accepted` when merged. Use `Superseded by ADR-NNN` if a later decision replaces it (do not delete the old one).

## Current ADRs
- [ADR-001: Session identity verification at async boundaries](ADR-001-session-identity-verification.md)
- [ADR-002: KVO for WKWebView state instead of @Published reads during SwiftUI updates](ADR-002-kvo-for-webview-state.md)
- [ADR-003: Topology grace periods instead of enumeration list replacement](ADR-003-topology-grace-periods.md)
- [ADR-004: Per-host state isolation for monitoring, reconnection, and errors](ADR-004-per-host-state-isolation.md)
- [ADR-005: SSH ControlMaster path constraints (~/.onyx/, no spaces)](ADR-005-ssh-controlmaster-paths.md)
- [ADR-006: Layered architecture with strict downward dependencies](ADR-006-layered-architecture.md)
