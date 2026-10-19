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

    private func granted() {
        access = .granted
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
            let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.store.events(matching: predicate).map(Self.event(from:))
            DispatchQueue.main.async { self.events = TodayEvent.ordered(events) }
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
