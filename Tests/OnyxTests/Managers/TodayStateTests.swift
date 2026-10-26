import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// TodayState is what the Today sections read, on the Mac and (later) on
/// the iPhone. These pin the parts that used to live on AppState, so the
/// move didn't change what the Mac shows.
final class TodayStateTests: XCTestCase {

    private var saved: AppearanceConfig!

    override func setUp() {
        super.setUp()
        saved = AppearanceStore.shared.config
    }

    override func tearDown() {
        AppearanceStore.shared.config = saved
        super.tearDown()
    }

    private func pr(_ number: Int, draft: Bool = false) -> PullRequest {
        PullRequest(provider: .github, repoFullName: "acme/api", number: number,
                    title: "Change \(number)", url: "https://github.com/acme/api/pull/\(number)",
                    openCommentThreads: 0, mergeStatus: .ready, headBranch: "b\(number)",
                    author: "me", apiSaysDraft: draft)
    }

    // MARK: - Settings

    func testTheAccentIsTheWindowsOwnOrTheGlobalOne() {
        AppearanceStore.shared.config.accentHex = "112233"
        AppearanceStore.shared.config.windowAccents = [2: "AABBCC"]
        XCTAssertEqual(TodayState(windowIndex: 2).accentHex, "AABBCC")
        XCTAssertEqual(TodayState(windowIndex: 1).accentHex, "112233")
    }

    /// The window's AppState answers from its Today, so the two can't
    /// disagree about the accent.
    func testAppStateTakesItsAccentFromToday() {
        let app = AppState()
        AppearanceStore.shared.config.windowAccents[app.windowIndex] = "C0FFEE"
        XCTAssertEqual(app.effectiveAccentHex, "C0FFEE")
        XCTAssertEqual(app.today.accentHex, "C0FFEE")
    }

    func testSettingTheAgendaPaneWritesTheSettingAndTellsThePlatform() {
        let today = TodayState(windowIndex: 1)
        var told: [AgendaPane] = []
        today.onAgendaPaneSet = { told.append($0) }
        AppearanceStore.shared.config.agendaPane = .reminders
        today.setAgendaPane(.calendar)
        XCTAssertEqual(AppearanceStore.shared.config.agendaPane, .calendar)
        XCTAssertEqual(told, [.calendar])
    }

    /// The Mac's part: in simple mode the pane is in the side panel, so a
    /// switch from a Today view opens it — not only the `A` key.
    func testASwitchFromATodayViewOpensTheSimpleModePanel() {
        let app = AppState()
        app.monitorLayout = .simple
        app.appearance.simpleShowSidePanel = false
        app.today.setAgendaPane(.calendar)
        XCTAssertTrue(app.appearance.simpleShowSidePanel)

        app.monitorLayout = .detailed
        app.appearance.simpleShowSidePanel = false
        app.today.setAgendaPane(.reminders)
        XCTAssertFalse(app.appearance.simpleShowSidePanel, "only simple mode keeps the pane in the panel")
    }

    func testTodayRedrawsWhenTheSettingsChange() {
        let today = TodayState(windowIndex: 1)
        let changed = expectation(description: "objectWillChange")
        let sub = today.objectWillChange.sink { changed.fulfill() }
        AppearanceStore.shared.config.use12HourClock.toggle()
        wait(for: [changed], timeout: 1)
        sub.cancel()
    }

    // MARK: - Open PRs

    func testTheDraftFilterDecidesWhichPRsAreVisible() {
        let prs = [pr(1), pr(2, draft: true), pr(3)]
        XCTAssertEqual(TodayState.visible(prs, filter: .all).map(\.number), [1, 2, 3])
        XCTAssertEqual(TodayState.visible(prs, filter: .hideDrafts).map(\.number), [1, 3])
        XCTAssertEqual(TodayState.visible(prs, filter: .onlyDrafts).map(\.number), [2])
    }

    // MARK: - The rule

    /// The sections the iPhone will show. Each must read TodayState and
    /// never the AppState: one that reaches for AppState works on the Mac
    /// and can't be shown on a phone, and nobody notices until it's ported.
    static let todaySections = [
        "SimpleTodayReminders", "SimpleTodayCalendar", "TodayCalendarSection",
        "AgendaPaneTabs", "SimplePullRequests", "SimplePipelinesStrip",
    ]

    func testNoTodaySectionTakesTheAppState() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Managers
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Sources/OnyxLib/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var found = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in Self.todaySections {
                guard let body = Self.declaration(of: name, in: text) else { continue }
                found.insert(name)
                XCTAssertFalse(body.contains("AppState") || body.contains("appState"),
                               "\(name) (\(file.lastPathComponent)) reads AppState; Today sections read TodayState")
            }
        }
        XCTAssertEqual(found, Set(Self.todaySections), "every section must be found, or the check proves nothing")
    }

    /// The text of `struct <name>` up to its closing brace.
    static func declaration(of name: String, in text: String) -> String? {
        guard let start = text.range(of: "struct \(name): View {") else { return nil }
        var depth = 0
        var index = start.lowerBound
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[start.lowerBound...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }
}
