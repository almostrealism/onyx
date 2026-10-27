//
// PadModel.swift
//
// Responsibility: What Onyx on an iPad knows beyond the phone's Today: the
//                 hosts every Mac shares, how to reach each one (the routes
//                 a Mac proved with the Onyx key), and the tmux sessions on
//                 them — listed over the built-in SSH client.
// Scope: One per app, shared by every window (scene).
// Threading: Main thread; listings run on a utility queue.
//
// docs/ios-plan.md, phase 5. The iPad reaches a host only through a route:
// the address, account and host key a Mac saw when it installed the Onyx
// key there ("Set up every host for iPad"). A shared host without one is
// listed — the user can see it exists — and says how to set it up, rather
// than guessing at an address a ~/.ssh/config alias only the Mac can read.
//

import Foundation
import Combine
import OnyxCore
import OnyxSSH
import OnyxToday

/// A host as the iPad lists it.
public struct PadHost: Identifiable, Equatable {
    /// As the Macs share it (its id is the one notes and favorites use).
    public let config: HostConfig
    /// How to reach it; nil until a Mac sets it up for the iPad.
    public let route: HomeHostPointer?

    public var id: UUID { config.id }
    public var label: String { config.label }

    /// What the built-in client connects to: the route's address under the
    /// shared host's id and name.
    public var connection: HostConfig? {
        guard let route else { return nil }
        var host = route.hostConfig
        host.label = config.label
        return host
    }
}

/// What the sidebar shows under a host.
public enum SessionListing: Equatable {
    case unknown
    case loading
    case listed([TmuxSession])
    case failed(String)
    /// No route: the iPad can't reach it yet.
    case notSetUp
}

public final class PadModel: ObservableObject {

    public let phone: TodayModel
    /// Agents on the hosts reaching this iPad.
    public let agents: PadAgents
    @Published public private(set) var hosts: [PadHost] = []
    @Published public private(set) var listings: [UUID: SessionListing] = [:]
    /// Session id → tmux's last activity, for "active 3m ago".
    @Published public private(set) var activity: [String: Date] = [:]

    private var inFlight: Set<UUID> = []
    private var poll: Timer?
    private var frontmost = true
    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "com.onyx.pad.sessions", qos: .utility, attributes: .concurrent)

    /// How often the sessions are listed again while the app is in front.
    public static let pollInterval: TimeInterval = 20

    public init(phone: TodayModel) {
        self.phone = phone
        agents = PadAgents(transport: phone.transport)
        let sync = SharedStateSync.shared
        sync.$sharedHosts.combineLatest(sync.$sharedRoutes, phone.$home)
            .receive(on: RunLoop.main)
            .sink { [weak self] hosts, routes, home in self?.update(shared: hosts, routes: routes, home: home) }
            .store(in: &cancellables)
        phone.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        startPolling()
        agents.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #if os(iOS)
        agents.start()
        #endif
    }

    /// A file beside the phone's own (Application Support/Onyx).
    public static func supportURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - Hosts

    /// The iPad's host list: every shared host, in the order the Macs
    /// publish them, each with its route. The home host is always there —
    /// it was proved when the device was paired, so it has a route even
    /// before the first sync brings the list.
    public static func hosts(shared: [HostConfig], routes: [String: HomeHostPointer],
                             home: HomeHostPointer?) -> [PadHost] {
        var list = shared.map { host in
            PadHost(config: host, route: routes[host.id.uuidString]
                        ?? (home?.hostID == host.id ? home : nil))
        }
        if let home, !list.contains(where: { $0.id == home.hostID }) {
            list.insert(PadHost(config: home.hostConfig, route: home), at: 0)
        }
        return list
    }

    private func update(shared: [HostConfig], routes: [String: HomeHostPointer], home: HomeHostPointer?) {
        let next = Self.hosts(shared: shared, routes: routes, home: home)
        // The first connection to each is checked against the key the Mac
        // saw, never trusted on sight.
        for route in next.compactMap(\.route) {
            KnownHostsStore.shared.pin(host: route.address, port: route.port, key: route.hostKey)
        }
        let added = next.filter { host in !hosts.contains { $0.id == host.id && $0.route == host.route } }
        hosts = next
        for host in next where host.route == nil { listings[host.id] = .notSetUp }
        for host in added where host.route != nil { refresh(host) }
    }

    public func host(_ id: UUID) -> PadHost? { hosts.first { $0.id == id } }

    // MARK: - Sessions

    public func sessions(on host: PadHost) -> [TmuxSession] {
        if case .listed(let sessions) = listings[host.id] { return sessions }
        return []
    }

    /// Every listed session, host by host.
    public var allSessions: [(host: PadHost, session: TmuxSession)] {
        hosts.flatMap { host in sessions(on: host).map { (host, $0) } }
    }

    public func refreshAll() {
        for host in hosts { refresh(host) }
    }

    /// List the host's sessions again. One listing per host at a time.
    public func refresh(_ host: PadHost) {
        guard let connection = host.connection, !inFlight.contains(host.id) else { return }
        inFlight.insert(host.id)
        if listings[host.id] == nil || listings[host.id] == .unknown || listings[host.id] == .notSetUp {
            listings[host.id] = .loading
        }
        let transport = phone.transport
        queue.async {
            let out = transport.runCommand(TmuxSessions.listScript(), on: connection,
                                           timeout: 15, label: "tmux ls:\(host.label)")
            let parsed = TmuxSessions.parse(out.stdout, source: .host(hostID: host.id))
            DispatchQueue.main.async {
                self.inFlight.remove(host.id)
                let listing = Self.listing(for: out, parsed: parsed.map(\.session))
                self.listings[host.id] = listing
                // A host that answered can reach back.
                if case .listed = listing { self.agents.reachAgents(on: host) }
                for (session, when) in parsed { if let when { self.activity[session.id] = when } }
            }
        }
    }

    /// A connection failure is a failure; anything else is a list — empty
    /// when the host has no tmux server running, which is not an error.
    static func listing(for out: RemoteOutput, parsed: [TmuxSession]) -> SessionListing {
        if out.isTransportFailure || out.exit == -1 {
            let why = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(why.isEmpty ? "couldn't connect" : why)
        }
        if out.timedOut { return .failed("no answer in 15 seconds") }
        return .listed(parsed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }

    /// A session that doesn't exist yet: the terminal creates it.
    public func newSession(named name: String, on host: PadHost) -> TmuxSession? {
        let safe = TmuxSessions.safeSession(name.trimmingCharacters(in: .whitespaces))
        guard !safe.isEmpty, host.route != nil else { return nil }
        return TmuxSession(name: safe, source: .host(hostID: host.id))
    }

    // MARK: - Foreground

    public func setFrontmost(_ active: Bool) {
        frontmost = active
        PadNotifier.isFrontmost = active
        phone.setFrontmost(active)
        if active { refreshAll() }
    }

    private func startPolling() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.frontmost else { return }
            self.refreshAll()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    // MARK: - The palette

    /// What ⌘K offers, best match first: every session, Today, and a new
    /// session on each reachable host when the query names one.
    public func paletteItems(query: String) -> [PaletteItem] {
        var items: [PaletteItem] = [.today]
        items += allSessions.map { .session($0.session, host: $0.host) }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if let url = PadWebTab.url(from: typed) { items.append(.web(url)) }
        if !typed.isEmpty {
            for host in hosts where host.route != nil {
                if let session = newSession(named: typed, on: host),
                   !sessions(on: host).contains(where: { $0.name == session.name }) {
                    items.append(.newSession(session, host: host))
                }
            }
        }
        return PaletteItem.ranked(items, query: typed)
    }
}

/// One line of the ⌘K palette.
public enum PaletteItem: Identifiable, Equatable {
    case today
    case session(TmuxSession, host: PadHost)
    case newSession(TmuxSession, host: PadHost)
    case web(URL)

    public var id: String {
        switch self {
        case .today: return "today"
        case .session(let s, _): return "session:\(s.id)"
        case .newSession(let s, _): return "new:\(s.id)"
        case .web(let url): return "web:\(url.absoluteString)"
        }
    }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .session(let s, let host): return "\(s.name) — \(host.label)"
        case .newSession(let s, let host): return "New session \"\(s.name)\" on \(host.label)"
        case .web(let url): return "Open \(url.absoluteString)"
        }
    }

    /// Text the query is matched against.
    var haystack: String {
        switch self {
        case .today: return "today"
        case .session(let s, let host): return "\(s.name) \(host.label)"
        case .newSession(let s, let host): return "\(s.name) \(host.label) new"
        case .web(let url): return url.absoluteString
        }
    }

    /// Subsequence match, scored: a match at the start of the text, and
    /// consecutive letters, rank higher. New-session lines always go last.
    static func ranked(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        guard !query.isEmpty else { return items.filter { if case .newSession = $0 { return false }; return true } }
        let scored = items.compactMap { item -> (PaletteItem, Int)? in
            if case .newSession = item { return (item, Int.min + 1) }
            if case .web = item { return (item, Int.max) }
            guard let score = score(query.lowercased(), in: item.haystack.lowercased()) else { return nil }
            return (item, score)
        }
        return scored.enumerated()
            .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
            .map(\.element.0)
    }

    static func score(_ query: String, in text: String) -> Int? {
        var score = 0
        var last: String.Index?
        var index = text.startIndex
        for ch in query {
            guard let found = text[index...].firstIndex(of: ch) else { return nil }
            if found == text.startIndex { score += 10 }
            if let last, text.index(after: last) == found { score += 5 }
            score -= text.distance(from: index, to: found)
            last = found
            index = text.index(after: found)
        }
        return score
    }
}
