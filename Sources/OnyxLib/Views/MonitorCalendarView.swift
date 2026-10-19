import SwiftUI

// MARK: - Today's calendar, in the monitor's agenda pane
//
// The agenda pane — the reminders column in the detailed layout, the list
// in simple mode's side panel — shows Reminders or today's calendar. `A`
// switches it, or click the header.

/// "REMINDERS · CALENDAR" — the pane's title, and the switch between the
/// two. The one showing is lit.
struct AgendaPaneTabs: View {
    @ObservedObject var appState: AppState
    /// What the reminders side is called right now ("TODAY", a list name).
    let remindersTitle: String

    var body: some View {
        HStack(spacing: 6) {
            tab(remindersTitle, .reminders)
            Text("·")
                .monitorFont(size: 10)
                .foregroundColor(.gray.opacity(0.3))
            tab("CALENDAR", .calendar)
        }
    }

    private func tab(_ title: String, _ pane: AgendaPane) -> some View {
        let selected = appState.appearance.agendaPane == pane
        return Button {
            guard !selected else { return }
            appState.appearance.agendaPane = pane
            appState.saveAppearance()
        } label: {
            Text(title)
                .monitorFont(size: 10, weight: .medium)
                .foregroundColor(selected ? appState.accentColor : .gray.opacity(0.4))
                .tracking(2)
        }
        .buttonStyle(.plain)
        .help(selected ? "" : "Show \(pane == .calendar ? "today's calendar" : "Reminders") here (A)")
    }
}

/// The detailed layout's agenda column, showing today's calendar: the
/// whole day, with what's over dimmed and what's on now marked.
struct TodayCalendarSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var calendar = TodayCalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgendaPaneTabs(appState: appState, remindersTitle: "REMINDERS")
                Spacer()
                if !calendar.events.isEmpty {
                    Text("\(calendar.events.count)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                CalendarEventList(events: calendar.events, access: calendar.access,
                                  now: context.date, accentColor: appState.accentColor,
                                  use12Hour: appState.appearance.use12HourClock,
                                  titleSize: 12, emptyText: "Nothing on the calendar today")
            }
        }
        .onAppear { calendar.activate() }
    }
}

/// Simple mode's agenda: what's left of today, capped.
struct SimpleTodayCalendar: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var calendar = TodayCalendarStore.shared

    /// Same budget as the reminders list it stands in for.
    private let maxShown = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AgendaPaneTabs(appState: appState, remindersTitle: "TODAY")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let left = TodayEvent.remaining(calendar.events, at: context.date)
                VStack(alignment: .leading, spacing: 5) {
                    CalendarEventList(events: Array(left.prefix(maxShown)), access: calendar.access,
                                      now: context.date, accentColor: appState.accentColor,
                                      use12Hour: appState.appearance.use12HourClock,
                                      titleSize: 13, emptyText: "Nothing more on the calendar today")
                    if left.count > maxShown {
                        Text("+\(left.count - maxShown) more")
                            .monitorFont(size: 10)
                            .foregroundColor(.gray.opacity(0.35))
                    }
                }
            }
        }
        .onAppear { calendar.activate() }
    }
}

/// The rows, shared by both layouts.
struct CalendarEventList: View {
    let events: [TodayEvent]
    let access: TodayCalendarStore.Access
    let now: Date
    let accentColor: Color
    /// The monitor clock's setting (`P`).
    let use12Hour: Bool
    let titleSize: CGFloat
    let emptyText: String

    var body: some View {
        switch access {
        case .notRequested:
            message("Asking for calendar access…")
        case .denied:
            message("Calendar access not granted. Allow Onyx in System Settings → Privacy & Security → Calendars.")
        case .granted:
            if events.isEmpty {
                message(emptyText)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events) { row($0) }
                }
            }
        }
    }

    private func row(_ event: TodayEvent) -> some View {
        let timing = event.timing(at: now)
        let color = event.colorHex.map { Color(hex: $0) } ?? accentColor
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(color.opacity(timing == .past ? 0.3 : 0.9))
                .frame(width: 6, height: 6)
            Text(timeLabel(event))
                .monitorFont(size: 10)
                // Lit only for the meeting you're in; an all-day event
                // is "on" all day and would always be lit.
                .foregroundColor(timing == .now && !event.isAllDay
                                 ? accentColor : .gray.opacity(timing == .past ? 0.3 : 0.55))
                .fixedSize()
            Text(event.title)
                .monitorFont(size: titleSize, weight: timing == .now && !event.isAllDay ? .medium : .regular)
                .foregroundColor(.white.opacity(timing == .past ? 0.35 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help([event.title, event.location, event.calendar].compactMap { $0 }.joined(separator: "\n"))
    }

    private func timeLabel(_ event: TodayEvent) -> String {
        if event.isAllDay { return "all day" }
        let f = DateFormatter()
        f.dateFormat = use12Hour ? "h:mm" : "H:mm"
        return "\(f.string(from: event.start))–\(f.string(from: event.end))"
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .monitorFont(size: 11)
            .foregroundColor(.gray.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
    }
}
