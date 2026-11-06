//
// SessionsWidget.swift
//
// Responsibility: The session widget itself — its timeline, read from the
//                 snapshot the app writes, and its views, small to large.
//                 The extension (Apps/OnyxWidget) is only its @main.
// Scope: WidgetKit and SwiftUI. Here rather than in the extension so the
//        tests can render it.
//

import SwiftUI
import WidgetKit

public struct SessionsEntry: TimelineEntry {
    public let date: Date
    /// Nil when the app has never written one (or this build can't reach
    /// the shared container).
    public let snapshot: SessionWidgetSnapshot?

    public init(date: Date, snapshot: SessionWidgetSnapshot?) {
        self.date = date
        self.snapshot = snapshot
    }
}

public struct SessionsProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: Date(), snapshot: .sample(at: Date()))
    }

    public func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        let now = Date()
        let stored = SessionWidgetStore.fileURL().flatMap(SessionWidgetStore.read)
        completion(SessionsEntry(date: now, snapshot: context.isPreview ? (stored ?? .sample(at: now)) : stored))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        let now = Date()
        let snapshot = SessionWidgetStore.fileURL().flatMap(SessionWidgetStore.read)
        // The app asks for a reload when rows change; between those, the
        // dots still need to fade as sessions go quiet, and the widget
        // needs to notice when the app stops writing. Both are dates
        // known now, so they're entries now.
        let dates = Self.entryDates(for: snapshot, now: now)
        let entries = dates.map { SessionsEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    /// Now, each moment a row's dot changes color in the next fifteen
    /// minutes, and the moment the snapshot goes stale.
    static func entryDates(for snapshot: SessionWidgetSnapshot?, now: Date) -> [Date] {
        guard let snapshot else { return [now] }
        let horizon = now.addingTimeInterval(15 * 60)
        var dates: Set<Date> = [now]
        for row in snapshot.rows {
            guard let last = row.lastActivity else { continue }
            for threshold in SessionActivityLevel.thresholds {
                let change = last.addingTimeInterval(threshold)
                if change > now && change < horizon { dates.insert(change) }
            }
        }
        let stale = snapshot.heartbeatAt.addingTimeInterval(SessionWidgetSnapshot.staleAfter + 1)
        if stale > now && stale < horizon { dates.insert(stale) }
        return dates.sorted()
    }
}

public struct OnyxSessionsWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: SessionWidgetStore.kind, provider: SessionsProvider()) { entry in
            SessionsWidgetView(entry: entry)
        }
        .configurationDisplayName("Onyx Sessions")
        .description("Your sessions with notes or Claudes, what each is doing, and your PRs' CI where there's room.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Views

/// Onyx's palette (OnyxCore's `Color.onyx…`), restated: the extension links
/// only this target.
enum WidgetPalette {
    static let accent = Color(red: 0x66 / 255, green: 0xCC / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x6B / 255, green: 0xFF / 255, blue: 0x8E / 255)
    static let amber = Color(red: 0xFF / 255, green: 0xD0 / 255, blue: 0x6B / 255)
    static let purple = Color(red: 0xC0 / 255, green: 0x6B / 255, blue: 0xFF / 255)
    static let red = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)

    static func pr(_ state: PRWidgetRow.State) -> Color {
        switch state {
        case .running: return accent.opacity(0.9)
        case .queued: return amber.opacity(0.85)
        case .failed: return red.opacity(0.85)
        case .passed: return green.opacity(0.7)
        }
    }

    static func dot(_ level: SessionActivityLevel) -> Color {
        switch level {
        case .active: return green
        case .recent: return amber
        case .quiet, .unknown: return .gray.opacity(0.5)
        }
    }
}

/// How many sessions and PRs a widget shows, counted in lines: a session
/// with a second line is two, any other row, header or "+N more" is one.
/// Sessions come first. PRs take what's left, so they appear only where
/// there's room, except that the large size keeps room for a few of them.
struct SessionsWidgetPlan: Equatable {
    var sessions: Int
    var prs: Int

    struct Budget {
        /// Lines under the top header.
        var lines: Int
        var maxSessions: Int
        /// PR rows kept free of sessions, when there are PRs.
        var reservedPRs: Int
        var maxPRs: Int
    }

    static func budget(for family: WidgetFamily) -> Budget {
        switch family {
        case .systemSmall: return Budget(lines: 6, maxSessions: 3, reservedPRs: 0, maxPRs: 0)
        // Measured at the sizes macOS draws, inside its 16pt margins.
        case .systemMedium: return Budget(lines: 7, maxSessions: 4, reservedPRs: 0, maxPRs: 4)
        case .systemExtraLarge: return Budget(lines: 18, maxSessions: 9, reservedPRs: 0, maxPRs: 0)
        default: return Budget(lines: 18, maxSessions: 9, reservedPRs: 3, maxPRs: 6)
        }
    }

    /// The extra-large size's own PR column, beside the sessions.
    static let columnPRs = Budget(lines: 18, maxSessions: 0, reservedPRs: 0, maxPRs: 14)

    static func plan(sessionLines: [Int], prCount: Int, budget: Budget) -> SessionsWidgetPlan {
        // A header, the rows, and the "+N more" when they don't all fit.
        let reserve = prCount > 0 && budget.reservedPRs > 0
            ? 1 + min(prCount, budget.reservedPRs) + (prCount > budget.reservedPRs ? 1 : 0) : 0
        let available = budget.lines - reserve
        var used = sessionLines.isEmpty ? 1 : 0          // "No sessions…"
        var shown = 0
        while shown < min(budget.maxSessions, sessionLines.count) {
            let more = shown + 1 < sessionLines.count ? 1 : 0
            guard used + sessionLines[shown] + more <= available else { break }
            used += sessionLines[shown]
            shown += 1
        }
        if shown < sessionLines.count { used += 1 }

        var prs = 0
        let left = budget.lines - used
        if prCount > 0, budget.maxPRs > 0, left >= 2 {
            prs = min(prCount, budget.maxPRs, left - 1)
            if prs < prCount, 1 + prs + 1 > left { prs -= 1 }
        }
        return SessionsWidgetPlan(sessions: shown, prs: max(0, prs))
    }

    /// Lines for a PR column with no sessions above it.
    static func column(prCount: Int, budget: Budget) -> Int {
        guard prCount > 0 else { return 0 }
        let room = min(prCount, budget.maxPRs, budget.lines - 1)
        return room < prCount && 1 + room + 1 > budget.lines ? room - 1 : room
    }
}

public struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var hostFamily
    let entry: SessionsEntry
    /// Set only to draw a size outside WidgetKit (the tests), where the
    /// family can't be put in the environment — and where `Link` can't be
    /// drawn, so rows are drawn without one.
    private let familyOverride: WidgetFamily?

    public init(entry: SessionsEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = family
    }

    private var family: WidgetFamily { familyOverride ?? hostFamily }

    private func plan(_ snapshot: SessionWidgetSnapshot) -> SessionsWidgetPlan {
        let lines = snapshot.rows.map { $0.detail == nil ? 1 : 2 }
        if family == .systemExtraLarge {
            let sessions = SessionsWidgetPlan.plan(sessionLines: lines, prCount: 0,
                                                   budget: SessionsWidgetPlan.budget(for: family))
            return SessionsWidgetPlan(sessions: sessions.sessions,
                                      prs: SessionsWidgetPlan.column(prCount: snapshot.prs.count,
                                                                     budget: SessionsWidgetPlan.columnPRs))
        }
        return SessionsWidgetPlan.plan(sessionLines: lines, prCount: snapshot.prs.count,
                                       budget: SessionsWidgetPlan.budget(for: family))
    }

    /// Links only inside WidgetKit, and never in the small size, which can
    /// only have its one `widgetURL`.
    private var linksRows: Bool { family != .systemSmall && familyOverride == nil }

    public var body: some View {
        content
            .containerBackground(for: .widget) { Color.black.opacity(0.85) }
            .widgetURL(family == .systemSmall
                       ? entry.snapshot?.rows.first.flatMap { SessionLink.url(for: $0.id) } : nil)
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            let plan = plan(snapshot)
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 5) {
                if family == .systemExtraLarge {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            header(snapshot)
                            sessions(snapshot, limit: plan.sessions)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: 5) {
                            if plan.prs > 0 {
                                pullRequests(snapshot.prs, limit: plan.prs)
                            } else {
                                prHeader
                                Text("No open PRs with CI to show.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    header(snapshot)
                    sessions(snapshot, limit: plan.sessions)
                    if plan.prs > 0 {
                        pullRequests(snapshot.prs, limit: plan.prs)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
                if snapshot.isStale(at: entry.date) {
                    Text("Onyx isn't running · as of \(snapshot.heartbeatAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundColor(WidgetPalette.amber.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("ONYX")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(WidgetPalette.accent)
                    .tracking(2)
                Text("Open Onyx to see your sessions here.")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private func sessions(_ snapshot: SessionWidgetSnapshot, limit: Int) -> some View {
        if snapshot.rows.isEmpty {
            Text("No sessions with a note or a Claude.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        } else {
            // Each row opens its session; the small widget can only have
            // one link, its first row (`widgetURL`).
            ForEach(snapshot.rows.prefix(limit)) { row in
                let view = SessionWidgetRowView(row: row, now: entry.date,
                                                compact: family == .systemSmall)
                if linksRows, let url = SessionLink.url(for: row.id) {
                    Link(destination: url) { view }
                } else {
                    view
                }
            }
            more(snapshot.rows.count - limit)
        }
    }

    @ViewBuilder private func pullRequests(_ prs: [PRWidgetRow], limit: Int) -> some View {
        prHeader
        ForEach(prs.prefix(limit)) { pr in
            let view = PRWidgetRowView(pr: pr)
            if linksRows, let url = URL(string: pr.url) {
                Link(destination: url) { view }
            } else {
                view
            }
        }
        more(prs.count - limit)
    }

    private var prHeader: some View {
        Text("OPEN PRs")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(WidgetPalette.accent)
            .tracking(2)
    }

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > 0 {
            Text("+\(count) more")
                .font(.system(size: 9))
                .foregroundColor(.gray.opacity(0.7))
        }
    }

    private func header(_ snapshot: SessionWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            Text(family == .systemSmall ? "ONYX" : "SESSIONS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(WidgetPalette.accent)
                .tracking(2)
            Spacer(minLength: 4)
            if snapshot.waitingCount > 0 {
                Label("\(snapshot.waitingCount)", systemImage: "brain.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WidgetPalette.amber)
                    .labelStyle(.titleAndIcon)
            } else if family == .systemSmall {
                Text("\(snapshot.rows.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
    }
}

struct SessionWidgetRowView: View {
    let row: SessionWidgetRow
    let now: Date
    /// The small widget: no clock or shortcut, so the title has the width.
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(WidgetPalette.dot(.of(idleSeconds: row.lastActivity.map { now.timeIntervalSince($0) })))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let n = row.shortcut, !compact {
                        Text("⌘\(n)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                    Text(row.title)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    if !compact, let last = row.lastActivity {
                        Spacer(minLength: 4)
                        // Time since it last did anything, as a clock
                        // WidgetKit keeps running without reloads.
                        Text(last, style: .timer)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 60, alignment: .trailing)
                    }
                }
                if let detail = row.detail {
                    detailLine(detail)
                }
            }
        }
    }

    @ViewBuilder private func detailLine(_ detail: String) -> some View {
        HStack(spacing: 4) {
            if let claude = row.claude {
                Image(systemName: claude == .waitingPermission ? "brain.fill" : "brain")
                    .font(.system(size: 8))
                    .foregroundColor(claude == .waitingPermission ? WidgetPalette.amber : WidgetPalette.purple)
            }
            Text(detail + (row.moreClaudes > 0 ? "  +\(row.moreClaudes)" : ""))
                .font(.system(size: 10))
                .foregroundColor(row.claude == .waitingPermission ? WidgetPalette.amber
                                 : row.claude != nil ? WidgetPalette.purple.opacity(0.9) : .gray)
                .lineLimit(1)
        }
    }
}

/// One PR: the branch, and its CI in simple mode's colors.
struct PRWidgetRowView: View {
    let pr: PRWidgetRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(pr.branch)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(pr.text)
                .font(.system(size: pr.state == .running || pr.state == .queued ? 11 : 10))
                .foregroundColor(WidgetPalette.pr(pr.state))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
    }
}

extension SessionWidgetSnapshot {
    /// What the widget gallery shows before the app has written anything.
    public static func sample(at now: Date) -> SessionWidgetSnapshot {
        SessionWidgetSnapshot(generatedAt: now, heartbeatAt: now, rows: [
            SessionWidgetRow(id: "a", title: "release prep", detail: "running Bash", claude: .running,
                             lastActivity: now.addingTimeInterval(-5), shortcut: 1),
            SessionWidgetRow(id: "b", title: "fix the flaky test", detail: "waiting for permission",
                             claude: .waitingPermission, lastActivity: now.addingTimeInterval(-40), shortcut: 2),
            SessionWidgetRow(id: "c", title: "docs", detail: "spark · docs", claude: nil,
                             lastActivity: now.addingTimeInterval(-900), shortcut: nil),
        ], pullRequests: [
            PRWidgetRow(id: "p1", branch: "feature/widget", title: "Session widget", url: "https://github.com",
                        state: .running, text: "build-macos"),
            PRWidgetRow(id: "p2", branch: "fix/flaky", title: "Fix the flaky test", url: "https://github.com",
                        state: .failed, text: "failed"),
            PRWidgetRow(id: "p3", branch: "docs/tour", title: "Docs", url: "https://github.com",
                        state: .passed, text: "passed"),
        ])
    }
}
