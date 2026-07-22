//
// HostHealth.swift
//
// Responsibility: Pure data types for connection truth — the per-host
//                 ConnectionPair health contract and the per-session
//                 connection state that drives the reconnect overlay,
//                 input gating, and the status pill.
// Scope: Models layer. No timers, no SSH, no ObservableObject.
//
// Invariants:
//   - SessionConnectionState has exactly ONE writer at runtime:
//     OnyxTerminalView (the terminal session manager). Everything else
//     (Views, AppState computed properties) only reads.
//   - HostHealth is derived and published only by a ConnectionPair.
//

import Foundation

// MARK: - Per-slot phase (one mux master = one slot)

/// Lifecycle phase of a single ControlMaster slot within a host's
/// connection pair.
public enum SlotPhase: Equatable, Sendable {
    /// No socket file, no process.
    case absent
    /// `ssh -M -N -f` in flight; bounded by a connect timeout.
    case establishing
    /// Socket exists, `-O check` passed, smoke test passing.
    case alive
    /// `-O check` passes but a smoke test or channel request failed —
    /// silent TCP death suspected; promotion is imminent.
    case suspect
    /// Socket gone or `-O check` failed after previously being alive.
    case dead
}

// MARK: - Per-host connection state (the pair, as one value)

/// The single health authority for one remote host. Everything that
/// talks to the host (terminals, pollers, UI) reads this; nothing else
/// decides "is the host up" on its own.
public enum HostConnectionState: Equatable, Sendable {
    /// Pair not yet created / first tick pending.
    case initializing
    /// At least one slot establishing; neither alive yet.
    case connecting
    /// Active slot alive. (Standby may also be alive — the healthy state.)
    case connected
    /// Active slot alive, standby dead — rebuilding standby in background.
    case degraded
    /// Active slot suspect; promotion to standby imminent.
    case failing
    /// Both slots dead; rebuild in progress.
    case down
    /// NWPathMonitor reports no network path; rebuilds paused.
    case offline
    /// System is asleep (willSleep received); masters quiesced.
    case sleeping

    /// Whether traffic (terminal attach, utility commands) can be sent
    /// through the pair right now.
    public var isUsable: Bool {
        switch self {
        case .connected, .degraded, .failing: return true
        case .initializing, .connecting, .down, .offline, .sleeping: return false
        }
    }
}

/// Snapshot of a host's connection pair, published by its ConnectionPair.
public struct HostHealth: Equatable, Sendable {
    public let hostID: UUID
    public let state: HostConnectionState
    public let activeSlotPhase: SlotPhase
    public let standbySlotPhase: SlotPhase
    /// ControlPath of the currently active slot — what mux clients dial.
    public let activeControlPath: String
    /// Monotonically increasing; bumped on every promotion/rebuild so
    /// consumers can detect "the connection changed under me".
    public let generation: UInt64
    public let lastTransition: Date

    public init(
        hostID: UUID,
        state: HostConnectionState,
        activeSlotPhase: SlotPhase,
        standbySlotPhase: SlotPhase,
        activeControlPath: String,
        generation: UInt64,
        lastTransition: Date
    ) {
        self.hostID = hostID
        self.state = state
        self.activeSlotPhase = activeSlotPhase
        self.standbySlotPhase = standbySlotPhase
        self.activeControlPath = activeControlPath
        self.generation = generation
        self.lastTransition = lastTransition
    }
}

// MARK: - Per-session connection state (drives overlay + input gating)

/// Connection state of one terminal session, keyed by session ID in
/// `AppState.sessionConnectionStates`. Replaces the old scattered flags
/// (`isReconnecting`, `reconnectingHostID`, `connectionError`,
/// `connectionErrorHostID`) with a single value whose transitions are
/// tied to events that actually change process liveness — never a timer.
public enum SessionConnectionState: Equatable {
    /// SSH process is running (or the session hasn't been touched yet —
    /// unknown sessions default to `.connected` so no spurious overlay
    /// appears before the manager has said anything).
    case connected
    /// The session's process is dead and the manager is re-attaching.
    case reattaching(reason: String, since: Date)
    /// Gave up: user action required.
    case failed(error: String)
    /// Key auth failed; user must install their SSH key.
    case needsKeySetup(error: String)

    /// Keystrokes must not silently go into a dead terminal.
    public var shouldGateInput: Bool {
        switch self {
        case .connected: return false
        case .reattaching, .failed, .needsKeySetup: return true
        }
    }

    /// Show the "Reconnecting…" overlay.
    public var showReconnectingOverlay: Bool {
        if case .reattaching = self { return true }
        return false
    }

    /// Show the connection-error overlay.
    public var showErrorOverlay: Bool {
        switch self {
        case .failed, .needsKeySetup: return true
        case .connected, .reattaching: return false
        }
    }

    /// User-facing message for the error overlay, if any.
    public var errorMessage: String? {
        switch self {
        case .failed(let error), .needsKeySetup(let error): return error
        case .connected, .reattaching: return nil
        }
    }
}
