import XCTest
import SwiftUI
import WidgetKit
@testable import OnyxWidgetKit
@testable import OnyxCore
@testable import OnyxLib

/// The session widget: what the app writes, when it asks for a reload,
/// what the widget makes of it, and the link back.
final class SessionWidgetTests: XCTestCase {

    /// Now, so the running clocks draw as they would on a desktop.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())

    private func row(_ id: String, claude: SessionWidgetRow.Claude? = nil, ago: TimeInterval? = 30,
                     title: String = "t") -> SessionWidgetRow {
        SessionWidgetRow(id: id, title: title, detail: nil, claude: claude,
                         lastActivity: ago.map { now.addingTimeInterval(-$0) }, shortcut: nil)
    }

    private func pr(_ id: String, _ state: PRWidgetRow.State, _ text: String? = nil) -> PRWidgetRow {
        PRWidgetRow(id: id, branch: "branch-\(id)", title: "PR \(id)", url: "https://github.com/o/r/pull/1",
                    state: state, text: text ?? state.rawValue)
    }

    // MARK: - The file

    func testASnapshotRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-widget-\(UUID().uuidString)/sessions-widget.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now,
                                             rows: [row("a", claude: .waitingPermission)])
        try SessionWidgetStore.write(snapshot, to: url)
        XCTAssertEqual(SessionWidgetStore.read(from: url), snapshot)
    }

    /// A file from a build that wrote no PRs still reads, with none.
    func testAFileWithoutPRsStillReads() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"{"version":1,"generatedAt":0,"heartbeatAt":0,"rows":[]}"#
        try Data(json.utf8).write(to: url)
        let read = try XCTUnwrap(SessionWidgetStore.read(from: url))
        XCTAssertEqual(read.prs, [])
    }

    func testTheGroupIsTheTeamPrefixedAppID() {
        XCTAssertEqual(SessionWidgetStore.groupID(teamID: "ABCDE12345"), "ABCDE12345.ai.almostrealism.onyx")
    }

    /// No heartbeat for fifteen minutes: the app isn't running, and the
    /// widget says so rather than passing old rows off as live.
    func testASnapshotGoesStaleWithoutAHeartbeat() {
        let snapshot = SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now, rows: [])
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(14 * 60)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(16 * 60)))
    }

    // MARK: - The link

    func testTheLinkCarriesTheSessionID() throws {
        let id = "host:1234/my session:2"
        let url = try XCTUnwrap(SessionLink.url(for: id))
        XCTAssertEqual(url.scheme, "onyx")
        XCTAssertEqual(SessionLink.sessionID(in: url), id)
        XCTAssertNil(SessionLink.sessionID(in: URL(string: "onyx://elsewhere?id=x")!))
        XCTAssertNil(SessionLink.sessionID(in: URL(string: "https://session?id=x")!))
    }

    // MARK: - Pacing

    func testTheFirstStepWritesAndReloads() {
        var pacing = SessionWidgetPacing()
        XCTAssertEqual(pacing.step([row("a")], now: now), .init(write: true, reload: true))
    }

    func testAChangedRowReloadsAtMostOnceAMinute() {
        var pacing = SessionWidgetPacing()
        _ = pacing.step([row("a", title: "one")], now: now)
        let soon = pacing.step([row("a", title: "two")], now: now.addingTimeInterval(20))
        XCTAssertEqual(soon, .init(write: true, reload: false))
        let later = pacing.step([row("a", title: "two")], now: now.addingTimeInterval(61))
        XCTAssertEqual(later, .init(write: false, reload: true), "the held-back change goes out once allowed")
    }

    /// A Claude waiting on you is the thing worth a reload right now.
    func testANewlyWaitingClaudeReloadsAtOnce() {
        var pacing = SessionWidgetPacing()
        _ = pacing.step([row("a", claude: .running)], now: now)
        let decision = pacing.step([row("a", claude: .waitingPermission)], now: now.addingTimeInterval(5))
        XCTAssertTrue(decision.reload)
    }

    /// Only the clocks moved: the file is written, the reload waits five
    /// minutes — the widget's own entries already fade the dots.
    func testANewlyFailedPRReloadsAtOnce() {
        var pacing = SessionWidgetPacing()
        _ = pacing.step([row("a")], prs: [pr("1", .running, "build")], now: now)
        // A job moving on waits for the minute…
        XCTAssertEqual(pacing.step([row("a")], prs: [pr("1", .running, "test")], now: now.addingTimeInterval(10)),
                       .init(write: true, reload: false))
        // …a failure doesn't.
        XCTAssertEqual(pacing.step([row("a")], prs: [pr("1", .failed)], now: now.addingTimeInterval(20)),
                       .init(write: true, reload: true))
        XCTAssertEqual(pacing.step([row("a")], prs: [pr("1", .running, "retry")], now: now.addingTimeInterval(80)),
                       .init(write: true, reload: true))
    }

    func testOnlyClocksMovingReloadsRarely() {
        var pacing = SessionWidgetPacing()
        _ = pacing.step([row("a", ago: 30)], now: now)
        XCTAssertEqual(pacing.step([row("a", ago: 1)], now: now.addingTimeInterval(90)),
                       .init(write: true, reload: false))
        XCTAssertTrue(pacing.step([row("a", ago: 0)], now: now.addingTimeInterval(301)).reload)
    }

    func testAnUnchangedListStillHeartbeats() {
        var pacing = SessionWidgetPacing()
        _ = pacing.step([row("a")], now: now)
        XCTAssertEqual(pacing.step([row("a")], now: now.addingTimeInterval(60)), .init(write: false, reload: false))
        XCTAssertEqual(pacing.step([row("a")], now: now.addingTimeInterval(301)), .init(write: true, reload: false))
    }

    // MARK: - The timeline

    /// The widget schedules an entry for each moment a dot changes color,
    /// and for the moment the snapshot goes stale.
    func testTheTimelineFadesDotsAndNoticesStaleness() {
        let snapshot = SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now,
                                             rows: [row("a", ago: 5)])
        let dates = SessionsProvider.entryDates(for: snapshot, now: now)
        XCTAssertEqual(dates.first, now)
        XCTAssertTrue(dates.contains(now.addingTimeInterval(10)), "green → amber at 15s idle")
        XCTAssertTrue(dates.contains(now.addingTimeInterval(115)), "amber → gray at 120s idle")
        XCTAssertEqual(SessionsProvider.entryDates(for: nil, now: now), [now])
    }

    func testTheDotThresholdsAreTheAppsToo() {
        XCTAssertEqual(SessionActivityLevel.of(idleSeconds: 3), .active)
        XCTAssertEqual(SessionActivityLevel.of(idleSeconds: 60), .recent)
        XCTAssertEqual(SessionActivityLevel.of(idleSeconds: 600), .quiet)
        XCTAssertEqual(SessionActivityLevel.of(idleSeconds: nil), .unknown)
    }

    // MARK: - The rows the app sends

    func testRowsSayWhatTheirClaudeIsDoingOrWhereTheyAre() {
        let host = UUID()
        let noted = TmuxSession(name: "work", source: .host(hostID: host))
        let matched = TmuxSession(name: "agent", source: .host(hostID: host))
        var waiting = ClaudeActivity(id: "c1", lastSeen: now, status: .waitingPermission)
        waiting.origin = HookOrigin(machine: "m", user: "u", session: "agent", pane: "%1")
        let running = ClaudeActivity(id: "c2", lastSeen: now.addingTimeInterval(-9), status: .running(tool: "Bash"))
        let entries = [
            SessionNoteEntry(session: noted, note: SessionNote(sessionID: noted.id, text: "ship it"), shortcut: 1,
                             claudes: [], lastActivity: now),
            SessionNoteEntry(session: matched, note: nil, shortcut: nil,
                             claudes: [running, waiting], lastActivity: now),
        ]
        let rows = AppState.widgetRows(entries)
        XCTAssertEqual(rows.map(\.title), ["ship it", matched.displayLabel])
        XCTAssertEqual(rows[0].detail, noted.displayLabel, "a note's row says where it is")
        XCTAssertNil(rows[0].claude)
        XCTAssertEqual(rows[0].shortcut, 1)
        XCTAssertEqual(rows[1].claude, .waitingPermission, "the Claude that needs you speaks")
        XCTAssertEqual(rows[1].detail, "waiting for permission")
        XCTAssertEqual(rows[1].moreClaudes, 1)
    }

    // MARK: - What fits

    private func plan(_ sessions: [Int], prs: Int, _ family: WidgetFamily) -> SessionsWidgetPlan {
        SessionsWidgetPlan.plan(sessionLines: sessions, prCount: prs,
                                budget: SessionsWidgetPlan.budget(for: family))
    }

    /// Sessions first; PRs only where there's room.
    func testPRsFillWhatSessionsLeave() {
        // A full medium stays sessions.
        XCTAssertEqual(plan([2, 2, 2, 2, 2], prs: 5, .systemMedium), .init(sessions: 3, prs: 0))
        XCTAssertEqual(plan([2, 2, 2, 2], prs: 5, .systemMedium), .init(sessions: 3, prs: 0))
        XCTAssertEqual(plan([1, 1, 1, 1], prs: 5, .systemMedium), .init(sessions: 4, prs: 1))
        // Two sessions leave three lines: a header and two PRs, or a header,
        // one PR and "+N more".
        XCTAssertEqual(plan([2, 2], prs: 2, .systemMedium), .init(sessions: 2, prs: 2))
        XCTAssertEqual(plan([2, 2], prs: 9, .systemMedium), .init(sessions: 2, prs: 1))
        // Never PRs in the small.
        XCTAssertEqual(plan([2], prs: 4, .systemSmall), .init(sessions: 1, prs: 0))
        // No PRs, nothing kept for them.
        XCTAssertEqual(plan(Array(repeating: 2, count: 12), prs: 0, .systemLarge).sessions, 8)
    }

    /// The large keeps room for a few PRs however many sessions there are,
    /// and gives them more when sessions don't need it.
    func testTheLargeKeepsRoomForPRs() {
        let many = Array(repeating: 2, count: 12)
        let busy = plan(many, prs: 8, .systemLarge)
        XCTAssertEqual(busy.prs, 3)
        XCTAssertEqual(busy.sessions, 6)
        let few = plan([2, 2], prs: 8, .systemLarge)
        XCTAssertEqual(few, .init(sessions: 2, prs: 6))
    }

    /// Whatever the mix, the plan never spends more lines than it has.
    func testAPlanFitsItsBudget() {
        for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
            let budget = SessionsWidgetPlan.budget(for: family)
            for n in 0...12 {
                for prs in 0...10 {
                    let lines = (0..<n).map { $0 % 3 == 0 ? 1 : 2 }
                    let p = plan(lines, prs: prs, family)
                    var used = n == 0 ? 1 : lines.prefix(p.sessions).reduce(0, +) + (p.sessions < n ? 1 : 0)
                    if p.prs > 0 { used += 1 + p.prs + (p.prs < prs ? 1 : 0) }
                    XCTAssertLessThanOrEqual(used, budget.lines, "\(family) \(n) sessions \(prs) PRs")
                    XCTAssertLessThanOrEqual(p.sessions, budget.maxSessions)
                }
            }
        }
    }

    /// The PRs are simple mode's: those with CI to show, saying what it's doing.
    func testPRRowsSayWhatTheirCIIsDoing() {
        let prs = (1...3).map {
            PullRequest(repoFullName: "o/r", number: $0, title: "PR \($0)",
                        url: "https://github.com/o/r/pull/\($0)", openCommentThreads: 0,
                        mergeStatus: .unknown, headBranch: "branch-\($0)")
        }
        let runs: [Int: [PRPipelineRun]] = [
            1: [PRPipelineRun(id: "r1", prID: "p1", name: "CI", overall: .running, runNumber: 1, attempt: 1,
                              url: nil, updatedAt: now,
                              activeJob: .init(name: "build", state: .running, since: now))],
            2: [PRPipelineRun(id: "r2", prID: "p2", name: "CI", overall: .failure, runNumber: 1, attempt: 1,
                              url: nil, updatedAt: now)],
        ]
        let rows = AppState.widgetPRs(prs) { runs[$0.number] ?? [] }
        XCTAssertEqual(rows.map(\.state), [.running, .failed])
        XCTAssertEqual(rows.map(\.text), ["build", "failed"])
        XCTAssertEqual(rows.first?.url, "https://github.com/o/r/pull/1")
    }

    // MARK: - Drawing

    private func busyRows() -> [SessionWidgetRow] {
        (0..<12).map { (i: Int) -> SessionWidgetRow in
            let plain = i % 3 == 0
            return SessionWidgetRow(id: "s\(i)", title: "session \(i)",
                                    detail: plain ? nil : "running Bash",
                                    claude: plain ? nil : .running,
                                    lastActivity: now.addingTimeInterval(-Double(i) * 50),
                                    shortcut: i < 9 ? i + 1 : nil)
        }
    }

    private func busyPRs() -> [PRWidgetRow] {
        let states: [PRWidgetRow.State] = [.running, .queued, .failed, .passed]
        return (0..<10).map { (i: Int) -> PRWidgetRow in
            pr("\(i)", states[i % 4], i % 4 < 2 ? "integration-tests" : nil)
        }
    }

    /// Every size draws, with rows, with none, stale, and before the app
    /// has written anything.
    @MainActor
    func testEveryFamilyRenders() throws {
        let cases: [SessionWidgetSnapshot?] = [
            .sample(at: now),
            SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now, rows: []),
            SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now.addingTimeInterval(-3600),
                                  rows: SessionWidgetSnapshot.sample(at: now).rows),
            nil,
            // Busy: more sessions and PRs than any size has room for.
            SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now, rows: busyRows(), pullRequests: busyPRs()),
            // One session and a few PRs: room for both everywhere but small.
            SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now,
                                  rows: Array(SessionWidgetSnapshot.sample(at: now).rows.prefix(1)),
                                  pullRequests: SessionWidgetSnapshot.sample(at: now).prs),
        ]
        let sizes: [(WidgetFamily, CGSize)] = [(.systemSmall, CGSize(width: 170, height: 170)),
                                               (.systemMedium, CGSize(width: 364, height: 170)),
                                               (.systemLarge, CGSize(width: 364, height: 382)),
                                               (.systemExtraLarge, CGSize(width: 772, height: 382))]
        let out = ProcessInfo.processInfo.environment["ONYX_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        for (i, snapshot) in cases.enumerated() {
            for (family, size) in sizes {
                let view = SessionsWidgetView(entry: SessionsEntry(date: now, snapshot: snapshot), family: family)
                    // WidgetKit's own content margins on macOS, so a
                    // render is as tight as the desktop.
                    .padding(16)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "case \(i) \(family)")
                if let out, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: out.appendingPathComponent("widget-\(i)-\(family).png"))
                }
            }
        }
    }
}
