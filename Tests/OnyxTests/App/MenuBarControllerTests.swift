import XCTest
@testable import OnyxLib

/// What the menu bar item shows, and in what order.
///
/// The rules matter more than they look: this menu exists to answer "which
/// session is bouncing" at a glance, so a session with an unseen alert
/// being anywhere but the top — or missing entirely because it has no note
/// — makes the feature useless in exactly the case it was built for.
final class MenuBarRowTests: XCTestCase {

    private func row(_ key: String, note: String? = nil,
                     noteAge: TimeInterval = 0,
                     alerts: [SessionAlert] = []) -> MenuBarController.Row {
        MenuBarController.Row(
            key: key,
            label: key,
            note: note.map { SessionNote(sessionID: key, text: $0,
                                         updated: Date().addingTimeInterval(-noteAge))
            },
            alerts: alerts)
    }

    private func alert(_ title: String, seen: Bool = false,
                       age: TimeInterval = 0) -> SessionAlert {
        SessionAlert(at: Date().addingTimeInterval(-age), title: title, seen: seen)
    }

    func testASessionWithNeitherNoteNorAlertIsNotListed() {
        let rows = MenuBarController.rows(from: [row("quiet")])
        XCTAssertTrue(rows.isEmpty)
    }

    /// The case the whole feature is for: an alerting session with no note
    /// must still appear, or the bounce has no explanation anywhere.
    func testASessionWithAlertsButNoNoteIsListed() {
        let rows = MenuBarController.rows(from: [row("loud", alerts: [alert("blocked")])])
        XCTAssertEqual(rows.map(\.key), ["loud"])
    }

    func testUnseenAlertsSortAboveEverythingElse() {
        let rows = MenuBarController.rows(from: [
            row("fresh-note", note: "just written", noteAge: 0),
            row("old-note", note: "ages ago", noteAge: 9_000),
            row("alerting", note: "older still", noteAge: 20_000,
                alerts: [alert("needs you", age: 600)]),
        ])
        XCTAssertEqual(rows.first?.key, "alerting",
                       "an unseen alert outranks the most recently written note")
    }

    /// "Seen" is not "unimportant" — the session stays listed — but it no
    /// longer jumps the queue.
    func testASeenAlertDoesNotJumpTheQueue() {
        let rows = MenuBarController.rows(from: [
            row("read", note: "old", noteAge: 9_000, alerts: [alert("done", seen: true, age: 60)]),
            row("recent", note: "new", noteAge: 5),
        ])
        XCTAssertEqual(rows.map(\.key), ["recent", "read"])
    }

    func testNotedSessionsWithoutAlertsSortByRecency() {
        let rows = MenuBarController.rows(from: [
            row("b", note: "second", noteAge: 100),
            row("a", note: "first", noteAge: 10),
            row("c", note: "third", noteAge: 1_000),
        ])
        XCTAssertEqual(rows.map(\.key), ["a", "b", "c"])
    }

    func testUnseenCountIgnoresSeenAlerts() {
        let r = row("k", alerts: [alert("one"), alert("two", seen: true), alert("three")])
        XCTAssertEqual(r.unseen, 2)
    }

    // MARK: - Text

    func testAlertLinesLeadWithTheTime() {
        let line = MenuBarController.alertLine(alert("Migration needs a decision"))
        XCTAssertTrue(line.contains("Migration needs a decision"))
        XCTAssertEqual(line.prefix(2).count, 2)
        XCTAssertTrue(line.contains(":"), "the time is first, so a column reads as a timeline")
    }

    /// A menu item is one line. An agent's multi-line title would
    /// otherwise stretch the menu to the width of the screen.
    func testLongAndMultilineTextIsFlattenedAndClipped() {
        XCTAssertEqual(MenuBarController.clip("one\ntwo", 40), "one two")
        let long = String(repeating: "x", count: 100)
        let clipped = MenuBarController.clip(long, 20)
        XCTAssertEqual(clipped.count, 20)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testShortTextIsLeftAlone() {
        XCTAssertEqual(MenuBarController.clip("  fine  ", 40), "fine")
    }
}

/// The status item's icon.
///
/// The mark is the product's identity in a row of thirty other icons. It
/// must not become a different glyph when it has news — that is precisely
/// when the user is scanning for it.
final class MenuBarIconTests: XCTestCase {

    func testTheMarkExistsInBothStates() {
        XCTAssertNotNil(MenuBarController.markImage(unread: false))
        XCTAssertNotNil(MenuBarController.markImage(unread: true))
    }

    func testTheUnreadStateIsTheSameMarkPlusABadge() {
        guard let quiet = MenuBarController.markImage(unread: false),
              let loud = MenuBarController.markImage(unread: true) else {
            return XCTFail("no image")
        }
        // Same glyph, grown just enough for the dot in the corner — not a
        // swap to some other symbol, which would be a different size
        // entirely and, more to the point, a different picture.
        XCTAssertGreaterThan(loud.size.width, quiet.size.width)
        XCTAssertLessThan(loud.size.width, quiet.size.width + 6)
        XCTAssertGreaterThan(loud.size.height, quiet.size.height)
    }

    /// Non-template images don't invert for a light menu bar, so a dark
    /// icon disappears against it.
    func testBothStatesAreTemplateImages() {
        XCTAssertTrue(MenuBarController.markImage(unread: false)?.isTemplate == true)
        XCTAssertTrue(MenuBarController.markImage(unread: true)?.isTemplate == true)
    }
}

/// Pipelines in the menu bar. Same question as the sessions list — "do I
/// need to go and look" — answered without switching to the app.
final class MenuBarPipelineTests: XCTestCase {

    private func status(_ name: String = "ci.yml",
                        repo: String = "acme/api",
                        overall: PipelineOverallStatus = .success,
                        attempt: Int? = nil,
                        branch: String? = "main") -> PipelineStatus {
        PipelineStatus(
            spec: PipelineSpec(url: "https://github.com/\(repo)/actions/workflows/\(name)",
                               provider: .github, path: repo,
                               target: .workflow(file: name, branch: nil)),
            runNumber: 42, runURL: "https://github.com/\(repo)/actions/runs/1",
            headBranch: branch, title: "t",
            succeeded: 1, inProgress: 0, queued: 0, skipped: 0, failed: 0,
            overall: overall, lastUpdated: Date(), attempt: attempt)
    }

    // MARK: - The attempt

    /// The ask: when a pipeline is on its second or later try, say so.
    /// It's invisible on the run's own page until you open it.
    func testARetryShowsItsAttemptNumber() {
        let line = MenuBarController.pipelineLine(status(attempt: 3))
        XCTAssertTrue(line.contains("attempt 3"), line)
    }

    /// "attempt 1" is every pipeline nobody has retried — printing it on
    /// all of them would hide the ones where it matters.
    func testAFirstAttemptSaysNothing() {
        XCTAssertFalse(MenuBarController.pipelineLine(status(attempt: 1)).contains("attempt"))
        XCTAssertFalse(MenuBarController.pipelineLine(status(attempt: nil)).contains("attempt"))
    }

    func testIsRetryTreatsAMissingAttemptAsTheFirst() {
        XCTAssertFalse(status(attempt: nil).isRetry)
        XCTAssertFalse(status(attempt: 1).isRetry)
        XCTAssertTrue(status(attempt: 2).isRetry)
    }

    // MARK: - The line

    func testTheLineNamesTheWorkflowAndTheRepo() {
        let line = MenuBarController.pipelineLine(status())
        XCTAssertTrue(line.contains("ci"))
        XCTAssertTrue(line.contains("acme/api"))
    }

    /// A default branch adds nothing; a feature branch is the reason the
    /// run looks unfamiliar.
    func testOnlyANonDefaultBranchIsNamed() {
        XCTAssertFalse(MenuBarController.pipelineLine(status(branch: "main")).contains("("))
        XCTAssertTrue(MenuBarController.pipelineLine(status(branch: "fix/thing"))
            .contains("fix/thing"))
    }

    func testTheLineStaysOneMenuWidth() {
        let long = status("really-long-workflow-name-that-goes-on.yml",
                          repo: "some-organisation/some-very-long-repository-name",
                          attempt: 12, branch: "feature/a-branch-with-a-long-name")
        XCTAssertLessThanOrEqual(MenuBarController.pipelineLine(long).count, 64)
    }

    // MARK: - Order

    /// "Is something wrong" before "what is happening".
    func testFailuresSortAboveRunningAndRunningAboveSuccess() {
        let ordered = [status("ok.yml", overall: .success),
                       status("go.yml", overall: .running),
                       status("bad.yml", overall: .failure)]
            .sorted(by: MenuBarController.mostInterestingFirst)
        XCTAssertEqual(ordered.map(\.overall), [.failure, .running, .success])
    }

    func testAMixedRunIsTreatedAsAFailure() {
        let ordered = [status("go.yml", overall: .running),
                       status("half.yml", overall: .mixed)]
            .sorted(by: MenuBarController.mostInterestingFirst)
        XCTAssertEqual(ordered.first?.overall, .mixed)
    }

    func testEqualUrgencySortsByName() {
        let ordered = [status("zebra.yml"), status("alpha.yml")]
            .sorted(by: MenuBarController.mostInterestingFirst)
        XCTAssertTrue(ordered.first!.spec.displayName.hasPrefix("alpha"))
    }
}
