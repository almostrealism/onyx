//
// RemoteEnvironment.swift
//
// Responsibility: What a per-window manager that talks to hosts needs from
//                 the app it runs in — the transport, the host it's
//                 looking at, and the connection gates — so the same
//                 manager (monitor, git, the editor, the file browser)
//                 runs in the Mac's AppState and in an iPad window.
// Scope: Protocol.
//
// The gates matter as much as the transport. On the Mac they are the
// ConnectionPair's: a host that's down, paused or saturated is skipped,
// not retried blind. An iPad window answers them for its own connection.
//

import Foundation
import Combine

public protocol RemoteEnvironment: AnyObject {
    /// What every remote call rides. Capture it on main, run off it.
    var transport: RemoteTransport { get }
    /// The host the window is showing; nil means this device's own.
    var activeHost: HostConfig? { get }
    /// Whether the host may be contacted now (not paused, not known down).
    func hostUsable(_ host: HostConfig?) -> Bool
    /// Claim a channel for `label` on the host; nil when this cycle must be
    /// skipped (the same poll is in flight, or the host is at its cap).
    /// Call the returned closure when done.
    func acquireUtilityChannel(_ label: String, host: HostConfig?) -> (() -> Void)?
    /// A connection failure (exit 255) against the host.
    func reportSSHFailure(host: HostConfig?)
    /// Fires when any host's connection health changes, so work skipped
    /// while a host was down can run when it's back.
    var hostHealthChanged: AnyPublisher<Void, Never> { get }
}
