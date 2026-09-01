import XCTest
@testable import OnyxLib

/// The session-activity indicator claims to say "how long since this
/// session produced output". It could only ever see sessions still in the
/// terminal pool, and the pool evicts anything unviewed for five minutes
/// — so for every other session it was really saying "how long since we
/// stopped watching", while looking identical. These cover the fix.
final class SessionActivityParseTests: XCTestCase {

    private let host = SessionSource.host(hostID: UUID())

    // MARK: - Parsing

    func testParsesNameAndActivityStamp() {
        let out = "onyx|1756000000\ntrainer|1756000600\n"
        let rows = OnyxTerminalView.parseSessionList(out, source: host)

        XCTAssertEqual(rows.map(\.session.name), ["onyx", "trainer"])
        XCTAssertEqual(rows[0].activity, Date(timeIntervalSince1970: 1_756_000_000))
        XCTAssertEqual(rows[1].activity, Date(timeIntervalSince1970: 1_756_000_600))
    }

    /// The delimiter has to be split off before the name is validated. The
    /// name rule rejects "|", so validating the whole line would reject
    /// every session and empty the list — with no error anywhere.
    func testTheStampDoesNotDisqualifyTheName() {
        let rows = OnyxTerminalView.parseSessionList("onyx|1756000000", source: host)
        XCTAssertEqual(rows.count, 1, "a session must survive having a timestamp attached")
        XCTAssertEqual(rows[0].session.name, "onyx")
    }

    /// A tmux old enough not to know `session_activity` expands it to
    /// nothing. Losing the timestamp is acceptable; losing the session is
    /// not.
    func testOldTmuxWithoutTheFieldStillYieldsSessions() {
        let rows = OnyxTerminalView.parseSessionList("onyx|\nbuild|", source: host)
        XCTAssertEqual(rows.map(\.session.name), ["onyx", "build"])
        XCTAssertNil(rows[0].activity)
        XCTAssertNil(rows[1].activity)
    }

    func testALineWithNoDelimiterAtAllStillYieldsASession() {
        let rows = OnyxTerminalView.parseSessionList("onyx", source: host)
        XCTAssertEqual(rows.map(\.session.name), ["onyx"])
        XCTAssertNil(rows[0].activity)
    }

    func testGarbageLinesAreStillRejected() {
        // The name rule exists because a broken shell echoes its own
        // script back at us; it has to keep working.
        let out = "onyx|1756000000\nbash: tmux: command not found\nzsh: event not found\n"
        let rows = OnyxTerminalView.parseSessionList(out, source: host)
        XCTAssertEqual(rows.map(\.session.name), ["onyx"])
    }

    func testNonNumericStampIsIgnoredRatherThanTrusted() {
        let rows = OnyxTerminalView.parseSessionList("onyx|not-a-time", source: host)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].activity)
    }
}

/// The store rules that keep a coarse external reading from making a live
/// session look dead.
final class ExternalActivityRecordingTests: XCTestCase {

    private func freshID() -> String { "session-\(UUID().uuidString)" }

    func testExternalActivitySeedsASessionTheSamplerNeverSaw() {
        // This is the whole point: a session that was evicted from the
        // pool has no local samples at all, and used to have no clock.
        let id = freshID()
        let when = Date().addingTimeInterval(-30)
        TerminalActivityStore.shared.recordExternal(sessionID: id, at: when)

        XCTAssertEqual(TerminalActivityStore.shared.lastOutput(for: id)?.timeIntervalSince1970 ?? 0,
                       when.timeIntervalSince1970, accuracy: 1)
    }

    func testAStaleExternalReadingNeverRewindsTheClock() {
        // The pooled sampler runs every 3s; enumeration every 15s. A
        // coarser, older reading must not make a session that just
        // produced output look stale.
        let id = freshID()
        let recent = Date().addingTimeInterval(-2)
        TerminalActivityStore.shared.recordExternal(sessionID: id, at: recent)
        TerminalActivityStore.shared.recordExternal(sessionID: id, at: Date().addingTimeInterval(-600))

        XCTAssertEqual(TerminalActivityStore.shared.lastOutput(for: id)?.timeIntervalSince1970 ?? 0,
                       recent.timeIntervalSince1970, accuracy: 1)
    }

    func testANewerExternalReadingAdvancesTheClock() {
        let id = freshID()
        TerminalActivityStore.shared.recordExternal(sessionID: id, at: Date().addingTimeInterval(-600))
        let newer = Date().addingTimeInterval(-5)
        TerminalActivityStore.shared.recordExternal(sessionID: id, at: newer)

        XCTAssertEqual(TerminalActivityStore.shared.lastOutput(for: id)?.timeIntervalSince1970 ?? 0,
                       newer.timeIntervalSince1970, accuracy: 1)
    }

    /// A host whose clock runs ahead would otherwise report activity in
    /// the future, and the session would sit on "0s ago" — permanently
    /// green, which is the failure mode that's hardest to notice.
    func testAHostClockInTheFutureIsClampedToNow() {
        let id = freshID()
        TerminalActivityStore.shared.recordExternal(sessionID: id,
                                                    at: Date().addingTimeInterval(3600))
        let recorded = TerminalActivityStore.shared.lastOutput(for: id) ?? .distantPast
        XCTAssertLessThanOrEqual(recorded.timeIntervalSince1970,
                                 Date().timeIntervalSince1970 + 1)
    }
}
