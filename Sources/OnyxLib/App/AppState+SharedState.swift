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
import Combine
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
        if !appearance.sshEngine.syncsBuiltIn { reportSSHFailure(host: host) }
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

    /// How the iPad reaches this Mac's hosts: the routes proved for the
    /// ones still configured here.
    public var ownRoutes: [HomeHostPointer]? {
        let ids = Set(hosts.map(\.id))
        return DeviceSyncManager.shared.routes.values.filter { ids.contains($0.hostID) }
            .sorted { $0.label < $1.label }
    }

    /// "Set up every host for iPad", then sync so the routes travel.
    func setUpHostsForDevices() {
        DeviceSyncManager.shared.setUpEveryHost(hosts, appState: self) {
            SharedStateSync.shared.syncNow()
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

/// The monitor, git, the editor and the file browser are OnyxCore's, shared
/// with the iPad; on the Mac their gates are the ConnectionPair's.
extension AppState: RemoteEnvironment {
    public var hostHealthChanged: AnyPublisher<Void, Never> {
        ConnectionPairRegistry.shared.$healthByHost.map { _ in () }.eraseToAnyPublisher()
    }
}
