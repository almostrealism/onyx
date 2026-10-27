import XCTest
@testable import OnyxCore
@testable import OnyxPad

/// The iPad's model, without a device: which hosts it lists and how it
/// reaches them, what a listing means, the palette, and the tabs.
final class PadTests: XCTestCase {

    private let homeID = UUID(), buildID = UUID(), labID = UUID()

    private func host(_ id: UUID, _ label: String) -> HostConfig {
        HostConfig(id: id, label: label, ssh: SSHConfig(host: label + "-alias", user: "me"))
    }

    private func route(_ id: UUID, _ label: String, port: Int = 22) -> HomeHostPointer {
        HomeHostPointer(hostID: id, label: label, address: "10.0.0.\(port % 250)", port: port,
                        user: "me", hostKey: "ssh-ed25519 AAAA")
    }

    // MARK: - Hosts

    func testEverySharedHostIsListedWithItsRoute() {
        let hosts = PadModel.hosts(shared: [host(homeID, "home"), host(buildID, "build"), host(labID, "lab")],
                                   routes: [buildID.uuidString: route(buildID, "build", port: 2222)],
                                   home: route(homeID, "home"))
        XCTAssertEqual(hosts.map(\.label), ["home", "build", "lab"], "the Macs' order")
        XCTAssertNotNil(hosts[0].route, "the home host's route is the pairing's")
        XCTAssertEqual(hosts[1].route?.port, 2222)
        XCTAssertNil(hosts[2].route, "listed, but not reachable until a Mac sets it up")
        XCTAssertNil(hosts[2].connection)
    }

    /// Before the first sync there's no list, but the home host is known.
    func testTheHomeHostIsThereBeforeTheFirstSync() {
        let hosts = PadModel.hosts(shared: [], routes: [:], home: route(homeID, "home"))
        XCTAssertEqual(hosts.map(\.id), [homeID])
        XCTAssertNotNil(hosts[0].connection)
    }

    /// The route says where to connect; the shared host says who it is —
    /// so notes and favorites, keyed by host id, are the Macs' own.
    func testTheConnectionIsTheRoutesAddressUnderTheSharedHostsName() throws {
        let pad = PadHost(config: host(buildID, "build"), route: route(buildID, "old name", port: 2200))
        let connection = try XCTUnwrap(pad.connection)
        XCTAssertEqual(connection.id, buildID)
        XCTAssertEqual(connection.label, "build")
        XCTAssertEqual(connection.ssh.host, "10.0.0.200")
        XCTAssertEqual(connection.ssh.port, 2200)
        XCTAssertNotEqual(connection.ssh.host, "build-alias", "an alias only the Mac's ~/.ssh/config knows")
    }

    // MARK: - Listings

    func testAConnectionFailureIsAFailureAndNoServerIsAnEmptyList() {
        let s = TmuxSession(name: "b", source: .host(hostID: buildID))
        let a = TmuxSession(name: "a", source: .host(hostID: buildID))
        XCTAssertEqual(PadModel.listing(for: RemoteOutput(exit: 255, stdout: "", stderr: "ssh: refused", timedOut: false),
                                        parsed: []), .failed("ssh: refused"))
        XCTAssertEqual(PadModel.listing(for: RemoteOutput(exit: 0, stdout: "", stderr: "", timedOut: false),
                                        parsed: []), .listed([]))
        XCTAssertEqual(PadModel.listing(for: RemoteOutput(exit: 0, stdout: "", stderr: "", timedOut: false),
                                        parsed: [s, a]), .listed([a, s]), "sorted by name")
    }

    func testTheAttachCommandCreatesOrAttachesAndIsSafe() {
        XCTAssertEqual(TmuxSessions.attachCommand("main"), "tmux -u new-session -A -s main")
        XCTAssertEqual(TmuxSessions.attachCommand("a b;rm -rf"), "tmux -u new-session -A -s a_b_rm_-rf")
        XCTAssertFalse(TmuxSessions.listScript().contains("!"), "zsh history expansion")
        XCTAssertTrue(TmuxSessions.listScript(container: "web;x").hasPrefix("docker exec web_x "))
    }

    // MARK: - The palette

    func testThePaletteRanksAndPutsNewSessionsLast() {
        let build = PadHost(config: host(buildID, "build"), route: route(buildID, "build"))
        let deploy = TmuxSession(name: "deploy", source: .host(hostID: buildID))
        let main = TmuxSession(name: "main", source: .host(hostID: buildID))
        let items: [PaletteItem] = [.today, .session(main, host: build), .session(deploy, host: build),
                                    .newSession(TmuxSession(name: "dep", source: .host(hostID: buildID)), host: build)]
        let ranked = PaletteItem.ranked(items, query: "dep")
        XCTAssertEqual(ranked.first, .session(deploy, host: build))
        XCTAssertEqual(ranked.last?.id, items[3].id)
        XCTAssertFalse(ranked.contains(.today), "no match, not shown")
        XCTAssertFalse(PaletteItem.ranked(items, query: "").contains { if case .newSession = $0 { return true }; return false },
                       "nothing typed, nothing to create")
    }

    // MARK: - Terminals and tabs

    private final class FakeTerminal: RemoteTerminal {
        var sent = Data(), sizes: [(Int, Int)] = [], closed = false
        func send(_ data: Data) { sent.append(data) }
        func resize(columns: Int, rows: Int) { sizes.append((columns, rows)) }
        func close() { closed = true }
    }

    private final class FakeProvider: RemoteTerminalProvider {
        var opened: [(command: String?, host: HostConfig)] = []
        var output: [(Data) -> Void] = []
        var ends: [(RemoteTerminalEnd) -> Void] = []
        var terminals: [FakeTerminal] = []
        func openTerminal(_ command: String?, on host: HostConfig, columns: Int, rows: Int, term: String,
                          onOutput: @escaping (Data) -> Void,
                          onEnd: @escaping (RemoteTerminalEnd) -> Void) -> RemoteTerminal {
            opened.append((command, host)); output.append(onOutput); ends.append(onEnd)
            let t = FakeTerminal(); terminals.append(t); return t
        }
    }

    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    func testOpeningASessionTwiceFocusesIt() {
        let provider = FakeProvider(), workspace = PadWorkspace()
        let build = PadHost(config: host(buildID, "build"), route: route(buildID, "build"))
        let deploy = TmuxSession(name: "deploy", source: .host(hostID: buildID))
        let first = workspace.open(deploy, on: build, using: provider)
        workspace.selection = .today
        let again = workspace.open(deploy, on: build, using: provider)
        XCTAssertTrue(first === again)
        XCTAssertEqual(provider.opened.count, 1)
        XCTAssertEqual(provider.opened[0].command, "tmux -u new-session -A -s deploy")
        XCTAssertEqual(provider.opened[0].host.ssh.host, "10.0.0.22")
        XCTAssertEqual(workspace.selection, .terminal(first.id))
    }

    func testOutputIsHeldUntilAViewIsThereAndTheEndIsReported() {
        let provider = FakeProvider(), workspace = PadWorkspace()
        let build = PadHost(config: host(buildID, "build"), route: route(buildID, "build"))
        let terminal = workspace.open(TmuxSession(name: "x", source: .host(hostID: buildID)), on: build, using: provider)
        provider.output[0](Data("hello ".utf8))
        provider.output[0](Data("world".utf8))
        drain()
        XCTAssertEqual(terminal.state, .live)
        var shown = Data()
        terminal.output = { shown.append($0) }
        XCTAssertEqual(String(decoding: shown, as: UTF8.self), "hello world")
        provider.ends[0](.exited(0))
        drain()
        XCTAssertEqual(terminal.state, .ended("Detached from x."))

        // Reattach: a new terminal, and the old one's late bytes are ignored.
        workspace.selection = .today
        workspace.open(terminal.session, on: build, using: provider)
        XCTAssertEqual(provider.opened.count, 2)
        provider.output[0](Data("stale".utf8))
        drain()
        XCTAssertFalse(String(decoding: shown, as: UTF8.self).contains("stale"))
    }

    func testAHostWithoutARouteSaysHowToSetItUp() {
        let provider = FakeProvider(), workspace = PadWorkspace()
        let lab = PadHost(config: host(labID, "lab"), route: nil)
        let terminal = workspace.open(TmuxSession(name: "x", source: .host(hostID: labID)), on: lab, using: provider)
        XCTAssertTrue(provider.opened.isEmpty)
        guard case .ended(let why) = terminal.state else { return XCTFail("\(terminal.state)") }
        XCTAssertTrue(why.contains("Set up every host for iPad"), why)
    }

    func testClosingATabHangsUpAndSelectsTheNext() {
        let provider = FakeProvider(), workspace = PadWorkspace()
        let build = PadHost(config: host(buildID, "build"), route: route(buildID, "build"))
        let a = workspace.open(TmuxSession(name: "a", source: .host(hostID: buildID)), on: build, using: provider)
        let b = workspace.open(TmuxSession(name: "b", source: .host(hostID: buildID)), on: build, using: provider)
        workspace.selection = .terminal(a.id)
        workspace.close(a)
        XCTAssertTrue(provider.terminals[0].closed)
        XCTAssertEqual(workspace.selection, .terminal(b.id))
        workspace.cycle(by: 1)
        XCTAssertEqual(workspace.selection, .today)
        workspace.close(b)
        XCTAssertEqual(workspace.selection, .today)
        XCTAssertTrue(workspace.terminals.isEmpty)
    }

    func testResizesReachTheRemoteOnlyWhenTheyChange() {
        let provider = FakeProvider(), workspace = PadWorkspace()
        let build = PadHost(config: host(buildID, "build"), route: route(buildID, "build"))
        let terminal = workspace.open(TmuxSession(name: "a", source: .host(hostID: buildID)), on: build, using: provider)
        terminal.resize(columns: 120, rows: 40)
        terminal.resize(columns: 120, rows: 40)
        terminal.resize(columns: 0, rows: 40)
        XCTAssertEqual(provider.terminals[0].sizes.count, 1)
        terminal.send(Data([0x1B]))
        XCTAssertEqual(provider.terminals[0].sent, Data([0x1B]))
    }
}
