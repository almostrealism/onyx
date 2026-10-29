//
// HostTunnel.swift
//
// Responsibility: Which host another is reached through — following
//                 `HostConfig.tunnelHostID`, refusing a loop, and which
//                 hosts may be offered as a tunnel at all.
// Scope: Pure data over the host list. The ssh arguments that carry a
//        connection through the tunnel host are the Mac's
//        (`AppState.tunnelProxyCommand`).
//

import Foundation

public enum HostTunnel {

    /// Why a tunneled host can't be connected to right now.
    public enum Problem: Error, Equatable {
        /// The tunnel host was deleted.
        case missing
        /// The hosts tunnel through each other.
        case loop
    }

    /// The tunnel hosts between this Mac and `host`, nearest first: [] for
    /// a host reached directly, [A] for one reached through A, [A, B] for
    /// one reached through B, which is itself reached through A.
    public static func chain(to host: HostConfig, in hosts: [HostConfig]) -> Result<[HostConfig], Problem> {
        var path: [HostConfig] = []
        var seen: Set<UUID> = [host.id]
        var next = host.tunnelHostID
        while let id = next {
            guard let hop = hosts.first(where: { $0.id == id }), !hop.isLocal else {
                return .failure(.missing)
            }
            guard seen.insert(id).inserted else { return .failure(.loop) }
            path.insert(hop, at: 0)
            next = hop.tunnelHostID
        }
        return .success(path)
    }

    /// The host `host` is reached through, if any and if it exists.
    public static func tunnelHost(of host: HostConfig, in hosts: [HostConfig]) -> HostConfig? {
        guard let id = host.tunnelHostID else { return nil }
        return hosts.first { $0.id == id && !$0.isLocal }
    }

    /// The hosts `host` may be reached through: any other remote host,
    /// except one that is itself reached through `host` (that would be
    /// a loop).
    public static func candidates(for host: HostConfig, in hosts: [HostConfig]) -> [HostConfig] {
        hosts.filter { other in
            guard other.id != host.id, !other.isLocal else { return false }
            guard case .success(let path) = chain(to: other, in: hosts) else { return false }
            return !path.contains { $0.id == host.id }
        }
    }

    /// The hosts reached through `host`, directly or further along.
    public static func dependents(of host: HostConfig, in hosts: [HostConfig]) -> [HostConfig] {
        hosts.filter { other in
            guard other.id != host.id, case .success(let path) = chain(to: other, in: hosts) else { return false }
            return path.contains { $0.id == host.id }
        }
    }
}
