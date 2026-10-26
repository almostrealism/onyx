//
// CalendarModels.swift
//
// Responsibility: Today's calendar as the monitor shows it, and which of
//                 Reminders or the calendar the monitor's agenda pane is
//                 showing.
// Scope: Pure data. EventKit is read by TodayCalendarStore; this is what
//        it reads into, so ordering and "what's on now" are testable
//        without a calendar.
//

import Foundation

/// What the monitor's agenda pane — the reminders column in the detailed
/// layout, the list in simple mode's side panel — is showing.
public enum AgendaPane: String, Codable, CaseIterable, Equatable {
    case reminders
    case calendar

    public var toggled: AgendaPane { self == .reminders ? .calendar : .reminders }
}

/// One event on today's calendar.
public struct TodayEvent: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The calendar's name and color, as the Calendar app shows them.
    public let calendar: String
    public let colorHex: String?
    public let location: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
                calendar: String, colorHex: String? = nil, location: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.calendar = calendar
        self.colorHex = colorHex; self.location = location
    }

    /// Where the event stands at `now`.
    public enum Timing: Equatable { case past, now, upcoming }

    public func timing(at now: Date) -> Timing {
        if isAllDay { return .now }
        if end <= now { return .past }
        if start <= now { return .now }
        return .upcoming
    }

    /// All-day events first, then by start time; ties by end, then title,
    /// so the list doesn't reshuffle between refreshes.
    public static func ordered(_ events: [TodayEvent]) -> [TodayEvent] {
        events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.title < b.title
        }
    }

    /// What's left of the day, in order: finished events drop off. For
    /// simple mode, where room is short and the past is no use.
    public static func remaining(_ events: [TodayEvent], at now: Date) -> [TodayEvent] {
        ordered(events).filter { $0.timing(at: now) != .past }
    }
}
