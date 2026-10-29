//
// TodayCalendarStore.swift
//
// Responsibility: Today's events from the Calendar app, for the monitor's
//                 agenda pane.
// Scope: Store — one EventKit client shared by every window.
//
// Asks for calendar access only when first activated — when someone
// switches the agenda pane to the calendar — never at launch. Most people
// will never use this, and an unexplained permission prompt on startup
// is worse than none.
//

import EventKit
import Foundation

public final class TodayCalendarStore: ObservableObject {

    public static let shared = TodayCalendarStore()

    public enum Access: Equatable {
        /// Not asked yet: nobody has switched to the calendar.
        case notRequested
        case granted
        case denied
    }

    @Published public private(set) var access: Access = .notRequested
    @Published public private(set) var events: [TodayEvent] = []
    /// Every event calendar EventKit shows us, hidden or not — for the
    /// choice in Settings, and to tell "no events" from "no calendars".
    @Published public private(set) var calendars: [CalendarChoice] = []
    /// What the agenda pane leaves out (`CalendarChoice.id`s).
    public private(set) var hidden: Set<String> = []

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: Any?

    private init() {}

    /// Ask for access if nobody has yet, and start keeping `events`
    /// current. Safe to call on every appearance.
    public func activate() {
        guard access == .notRequested else { return }
        // What macOS already decided, without prompting again.
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            granted()
        case .denied, .restricted, .writeOnly:
            access = .denied
        default:
            store.requestFullAccessToEvents { [weak self] ok, _ in
                DispatchQueue.main.async {
                    if ok { self?.granted() } else { self?.access = .denied }
                }
            }
        }
    }

    /// Leave these calendars out, from now on.
    public func setHidden(_ ids: Set<String>) {
        guard ids != hidden else { return }
        hidden = ids
        refresh()
    }

    /// The calendars that are drawn from, of those EventKit shows.
    public var shownCalendarCount: Int {
        calendars.filter { !hidden.contains($0.id) }.count
    }

    private func granted() {
        access = .granted
        // A store made before access was granted can go on answering as
        // though it had none — no calendars, so no events, ever — until
        // it's told to read again.
        store.reset()
        refresh()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // A minute is fine for "what's next", and it also rolls the list
        // over at midnight.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    public func refresh() {
        guard access == .granted else { return }
        let hidden = self.hidden
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
            let all = self.store.calendars(for: .event)
            let choices = all.map {
                CalendarChoice(title: $0.title, source: $0.source?.title ?? "",
                               colorHex: $0.cgColor.flatMap(Self.hex(of:)))
            }
            let shown = all.filter {
                !hidden.contains(CalendarChoice.key(source: $0.source?.title ?? "", title: $0.title))
            }
            var events: [TodayEvent] = []
            // An empty list means every calendar to EventKit, so nothing
            // shown has to be asked for as nothing.
            if !shown.isEmpty {
                let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: shown)
                events = self.store.events(matching: predicate).map(Self.event(from:))
            }
            DispatchQueue.main.async {
                self.calendars = choices
                self.events = TodayEvent.ordered(events)
            }
        }
    }

    private static func event(from e: EKEvent) -> TodayEvent {
        TodayEvent(
            // Recurring events share an identifier; the start tells
            // today's occurrence apart.
            id: "\(e.eventIdentifier ?? e.calendarItemIdentifier)@\(e.startDate.timeIntervalSince1970)",
            title: e.title?.isEmpty == false ? e.title! : "Untitled",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            calendar: e.calendar?.title ?? "",
            colorHex: e.calendar?.cgColor.flatMap(hex(of:)),
            location: e.location?.isEmpty == false ? e.location : nil)
    }

    private static func hex(of color: CGColor) -> String? {
        guard let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        return String(format: "%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
    }
}
