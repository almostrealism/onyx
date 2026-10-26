//
// AppState+SharedState.swift
//
// Responsibility: The Mac's side of shared-state sync — what
//                 SharedStateSync (in OnyxCore, shared with the iOS apps)
//                 needs from the app: the hosts, the transport, the
//                 connection gate, and this Mac's hosts to publish.
//

import Foundation
import AppKit
import OnyxCore

extension AppState: SharedStateEnvironment {

    public var sharedStateHosts: [HostConfig] { hosts }

    public func canSync(with host: HostConfig) -> Bool { hostUsable(host) }

    public func claimSyncSlot(for host: HostConfig) -> (() -> Void)? {
        acquireUtilityChannel("sharedState:\(host.id)", host: host)
    }

    /// A dead connection is the ConnectionPair's to recover — but only when
    /// it was the pair's connection. The built-in client keeps its own, and
    /// failing over the pair for its trouble would drop healthy terminals.
    public func syncConnectionFailed(host: HostConfig) {
        if appearance.sshEngine == .openSSH { reportSSHFailure(host: host) }
    }

    public var isFrontmost: Bool { NSApp?.isActive ?? true }

    /// This Mac's remote hosts, for the iPad. The key path is blanked:
    /// it names a file on this Mac, which means nothing anywhere else.
    public var ownHosts: [HostConfig]? {
        hosts.filter { !$0.isLocal }.map { host in
            var shared = host
            shared.ssh.identityFile = ""
            return shared
        }
    }

    /// Tell the sync when the app comes to the front.
    static let observeActivationForSharedState: Void = {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            SharedStateSync.shared.appDidBecomeActive()
        }
    }()
}
