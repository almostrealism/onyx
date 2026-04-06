import Foundation

// MARK: - Network Topology

public enum ProbeStatus: String, Codable {
    case ok
    case unreachable
    case keyAuthFailed
}

public struct TopologyEntry: Codable {
    public var id: String           // session ID
    public var name: String
    public var source: SessionSource
    public var lastSeen: Date       // last confirmed alive
    public var lastEnumerated: Date // last time we checked
    public var alive: Bool

    /// Confidence score: 1.0 = seen within 30s, decays to 0.0 over 10 minutes
    public var confidence: Double {
        guard alive else { return 0 }
        let age = Date().timeIntervalSince(lastSeen)
        if age <= 30 { return 1.0 }
        return max(0, 1.0 - (age - 30) / 570) // linear decay from 30s to 600s
    }
}

public struct ContainerEntry: Codable {
    public var name: String
    public var lastSeen: Date
    public var alive: Bool
}

public struct HostTopology: Codable {
    public var hostID: UUID
    public var containers: [String: ContainerEntry]   // name -> entry
    public var sessions: [String: TopologyEntry]       // sessionID -> entry
    public var lastProbeTime: Date?
    public var lastProbeResult: ProbeStatus?
}

public class NetworkTopologyStore: ObservableObject {
    public static let shared = NetworkTopologyStore()

    @Published public var hosts: [UUID: HostTopology] = [:]
    private var url: URL?
    private let lock = NSLock()

    private init() {}

    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        load()
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([UUID: HostTopology].self, from: data) {
            self.hosts = decoded
        }
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(hosts) {
            try? data.write(to: url)
        }
    }

    /// Merge enumeration results for a host. Found sessions become alive; missing ones
    /// get a 30s grace period before being marked dead. Unreachable hosts are left untouched.
    public func mergeEnumeration(hostID: UUID, sessions: [TmuxSession], probeResult: ProbeStatus) {
        lock.lock()
        defer { lock.unlock() }

        var topo = hosts[hostID] ?? HostTopology(hostID: hostID, containers: [:], sessions: [:])
        topo.lastProbeTime = Date()
        topo.lastProbeResult = probeResult

        // If unreachable or key auth failed, don't touch session entries — they may still be alive
        guard probeResult == .ok else {
            hosts[hostID] = topo
            return
        }

        let now = Date()
        let foundIDs = Set(sessions.map(\.id))

        // Update found sessions
        for session in sessions {
            var entry = topo.sessions[session.id] ?? TopologyEntry(
                id: session.id, name: session.name, source: session.source,
                lastSeen: now, lastEnumerated: now, alive: true
            )
            entry.alive = true
            entry.lastSeen = now
            entry.lastEnumerated = now
            entry.name = session.name
            entry.source = session.source
            topo.sessions[session.id] = entry

            // Track containers
            if let containerName = session.source.containerName {
                topo.containers[containerName] = ContainerEntry(name: containerName, lastSeen: now, alive: true)
            }
        }

        // Mark missing sessions dead after 30s grace period
        for (id, var entry) in topo.sessions where !foundIDs.contains(id) {
            guard entry.source.hostID == hostID else { continue }
            entry.lastEnumerated = now
            if entry.alive && now.timeIntervalSince(entry.lastSeen) > 30 {
                entry.alive = false
            }
            topo.sessions[id] = entry
        }

        // Mark containers not found in enumeration
        let foundContainers = Set(sessions.compactMap(\.source.containerName))
        for (name, var container) in topo.containers where !foundContainers.contains(name) {
            if container.alive && now.timeIntervalSince(container.lastSeen) > 30 {
                container.alive = false
            }
            topo.containers[name] = container
        }

        hosts[hostID] = topo
    }

    /// Confirm specific containers are alive (called from docker stats polling).
    /// This keeps entries fresh even when full enumeration hasn't run recently.
    public func confirmContainersAlive(hostID: UUID, containerNames: [String]) {
        lock.lock()
        defer { lock.unlock() }

        var topo = hosts[hostID] ?? HostTopology(hostID: hostID, containers: [:], sessions: [:])
        let now = Date()

        for name in containerNames {
            topo.containers[name] = ContainerEntry(name: name, lastSeen: now, alive: true)

            // Also refresh any sessions belonging to this container
            for (id, var entry) in topo.sessions {
                if entry.source.containerName == name {
                    entry.lastSeen = now
                    entry.alive = true
                    topo.sessions[id] = entry
                }
            }
        }

        hosts[hostID] = topo
    }

    /// Derive TmuxSession list from topology. Alive entries are normal sessions;
    /// recently-dead entries (< 10 min) show as unavailable. Older entries are hidden.
    public func deriveSessions() -> [TmuxSession] {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        var result: [TmuxSession] = []

        for (_, topo) in hosts {
            for (_, entry) in topo.sessions {
                if entry.alive {
                    result.append(TmuxSession(name: entry.name, source: entry.source))
                } else if now.timeIntervalSince(entry.lastSeen) < 600 {
                    // Recently dead — show as unavailable (stale)
                    result.append(TmuxSession(name: entry.name, source: entry.source, unavailable: true))
                }
                // Older than 10 min dead: not shown but kept in topology
            }
        }

        return result
    }

    /// Garbage-collect entries not seen in 24 hours
    public func gc() {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = Date().addingTimeInterval(-86400) // 24h

        for (hostID, var topo) in hosts {
            topo.sessions = topo.sessions.filter { $0.value.lastSeen > cutoff }
            topo.containers = topo.containers.filter { $0.value.lastSeen > cutoff }
            hosts[hostID] = topo
        }
    }

    /// Get confidence for a container by name on a host
    public func containerConfidence(hostID: UUID, containerName: String) -> Double {
        lock.lock()
        defer { lock.unlock() }

        guard let topo = hosts[hostID],
              let container = topo.containers[containerName] else { return 0 }
        guard container.alive else { return 0 }
        let age = Date().timeIntervalSince(container.lastSeen)
        if age <= 30 { return 1.0 }
        return max(0, 1.0 - (age - 30) / 570)
    }

    /// Get probe status for a host
    public func probeStatus(hostID: UUID) -> (result: ProbeStatus?, time: Date?) {
        lock.lock()
        defer { lock.unlock() }
        guard let topo = hosts[hostID] else { return (nil, nil) }
        return (topo.lastProbeResult, topo.lastProbeTime)
    }

    /// Reset for testing
    public func reset() {
        lock.lock()
        hosts = [:]
        lock.unlock()
    }
}
