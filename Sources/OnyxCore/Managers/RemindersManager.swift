//
// RemindersManager.swift
//
// Responsibility: Reminders from EventKit — today's across every list, or
//                 the lists the user chose — plus the due-today and
//                 due-by-tomorrow counts.
// Scope: One per view that lists reminders; Today's lives on TodayState.
//

import Foundation
import EventKit
import Combine

/// A group of reminders under one list name
public struct ReminderListGroup: Identifiable {
    public let id: String   // list name
    public let name: String
    public let reminders: [EKReminder]

    public init(id: String, name: String, reminders: [EKReminder]) {
        self.id = id
        self.name = name
        self.reminders = reminders
    }
}

public class RemindersManager: ObservableObject {
    @Published public var reminders: [EKReminder] = []
    /// Reminders grouped by list, in the order of selectedLists
    @Published public var groupedReminders: [ReminderListGroup] = []
    @Published public var accessGranted = false
    @Published public var availableLists: [String] = []

    /// Scope counts across ALL lists, independent of selectedLists — for
    /// the "how much is due" indicator. dueTodayCount is incomplete
    /// reminders due by end of today (overdue included); dueTomorrowCount
    /// is the cumulative count due by end of tomorrow (so it's always
    /// ≥ dueTodayCount and shows how much the load grows tomorrow).
    @Published public var dueTodayCount: Int = 0
    @Published public var dueTomorrowCount: Int = 0

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var changeObserver: Any?
    public var selectedLists: [String] = []  // empty = "Today" (due today across all lists)

    /// True when showing multiple lists (grouped display)
    public var isMultiList: Bool { selectedLists.count > 1 }

    /// Display name for the header
    public var displayName: String {
        if selectedLists.isEmpty { return "TODAY" }
        if selectedLists.count == 1 { return selectedLists[0].uppercased() }
        return "REMINDERS"
    }

    /// Total count across all groups
    public var totalCount: Int {
        if isMultiList { return groupedReminders.reduce(0) { $0 + $1.reminders.count } }
        return reminders.count
    }

    /// Empty-state message
    public var emptyMessage: String {
        selectedLists.isEmpty ? "No reminders due today" : "No reminders"
    }

    public init() {
        requestAccess()

        // Refresh when reminders change externally (other apps, iCloud sync)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            self?.refreshLists()
            self?.fetchReminders()
            self?.fetchScopeCounts()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        if let obs = changeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func requestAccess() {
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.accessGranted = granted
                if granted {
                    self?.refreshLists()
                    self?.fetchReminders()
                    self?.fetchScopeCounts()
                    self?.startTimer()
                }
            }
        }
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchReminders()
            self?.fetchScopeCounts()
        }
    }

    public func refreshLists() {
        let calendars = store.calendars(for: .reminder)
        availableLists = calendars.map(\.title).sorted()
    }

    public func fetchReminders() {
        guard accessGranted else { return }

        if selectedLists.isEmpty {
            // "Today" mode: incomplete reminders due by end of today, across all lists
            fetchTodayReminders(calendars: nil)
        } else if selectedLists.count == 1 {
            // Single list: flat display
            let match = store.calendars(for: .reminder).filter { selectedLists.contains($0.title) }
            if match.isEmpty {
                DispatchQueue.main.async { self.reminders = []; self.groupedReminders = [] }
            } else {
                fetchListReminders(calendars: match)
            }
        } else {
            // Multiple lists: fetch per-list and group
            fetchGroupedReminders()
        }
    }

    private func fetchTodayReminders(calendars: [EKCalendar]?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            // Last second of today, not start-of-tomorrow: the predicate's
            // end is inclusive, so an all-day reminder due tomorrow (which
            // resolves to tomorrow 00:00) would otherwise be pulled into
            // today's list. See fetchScopeCounts for the same fix.
            let endOfDay = cal.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay)!

            let predicate = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: endOfDay,
                calendars: calendars
            )

            self.store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted { a, b in
                    let da = a.dueDateComponents?.date ?? .distantFuture
                    let db = b.dueDateComponents?.date ?? .distantFuture
                    return da < db
                }
                DispatchQueue.main.async {
                    self.reminders = sorted
                }
            }
        }
    }

    private func fetchListReminders(calendars: [EKCalendar]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            let predicate = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: calendars
            )

            self.store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted { a, b in
                    let pa = a.priority
                    let pb = b.priority
                    // Sort by priority (1=high, 5=medium, 9=low, 0=none→last)
                    let normA = pa == 0 ? 100 : pa
                    let normB = pb == 0 ? 100 : pb
                    if normA != normB { return normA < normB }
                    let da = a.dueDateComponents?.date ?? .distantFuture
                    let db = b.dueDateComponents?.date ?? .distantFuture
                    return da < db
                }
                DispatchQueue.main.async {
                    self.reminders = sorted
                }
            }
        }
    }

    private func fetchGroupedReminders() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let allCalendars = self.store.calendars(for: .reminder)
            let listOrder = self.selectedLists
            var groups: [ReminderListGroup] = []

            for listName in listOrder {
                guard let calendar = allCalendars.first(where: { $0.title == listName }) else { continue }
                let predicate = self.store.predicateForIncompleteReminders(
                    withDueDateStarting: nil, ending: nil, calendars: [calendar]
                )
                // fetchReminders is async with callback — use a semaphore for sequential fetch
                let sem = DispatchSemaphore(value: 0)
                var fetched: [EKReminder] = []
                self.store.fetchReminders(matching: predicate) { reminders in
                    fetched = (reminders ?? []).sorted { a, b in
                        let normA = a.priority == 0 ? 100 : a.priority
                        let normB = b.priority == 0 ? 100 : b.priority
                        if normA != normB { return normA < normB }
                        let da = a.dueDateComponents?.date ?? .distantFuture
                        let db = b.dueDateComponents?.date ?? .distantFuture
                        return da < db
                    }
                    sem.signal()
                }
                sem.wait()
                groups.append(ReminderListGroup(id: listName, name: listName, reminders: fetched))
            }

            DispatchQueue.main.async {
                self.groupedReminders = groups
                self.reminders = groups.flatMap(\.reminders)
            }
        }
    }

    /// Count incomplete reminders due by end of today and by end of
    /// tomorrow, across every list. Runs regardless of which lists are
    /// currently displayed. The predicate requires a due date, so
    /// dateless reminders are correctly excluded from "what's due".
    public func fetchScopeCounts() {
        guard accessGranted else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            // predicateForIncompleteReminders(ending:) is *inclusive*, and an
            // all-day (date-only) reminder due tomorrow resolves to tomorrow
            // 00:00 — i.e. exactly start-of-tomorrow. Ending the window there
            // would pull every such reminder one day early. End at the last
            // second of the day instead so tomorrow's midnight stays out.
            let endOfToday = cal.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay)!
            let endOfTomorrow = cal.date(byAdding: DateComponents(day: 2, second: -1), to: startOfDay)!

            let todayPred = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: endOfToday, calendars: nil)
            let tomorrowPred = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: endOfTomorrow, calendars: nil)

            let group = DispatchGroup()
            var todayN = 0, tomorrowN = 0
            group.enter()
            self.store.fetchReminders(matching: todayPred) { rs in
                todayN = (rs ?? []).count; group.leave()
            }
            group.enter()
            self.store.fetchReminders(matching: tomorrowPred) { rs in
                tomorrowN = (rs ?? []).count; group.leave()
            }
            group.notify(queue: .main) {
                self.dueTodayCount = todayN
                self.dueTomorrowCount = tomorrowN
            }
        }
    }

    /// Is this reminder due by the end of tomorrow (overdue included)?
    ///
    /// Uses the same window as `fetchScopeCounts` so the "today / by tmrw"
    /// chips and the filtered list can never disagree: the last second of
    /// tomorrow, because an all-day reminder due the day after tomorrow
    /// resolves to that day's 00:00 and must stay out. Reminders with no
    /// due date are excluded — "due soon" is about dated work.
    public static func isDueSoon(_ reminder: EKReminder, now: Date = Date()) -> Bool {
        isDueSoon(due: reminder.dueDateComponents, now: now)
    }

    /// The date rule on its own, so it's testable without an EventKit store.
    public static func isDueSoon(due comps: DateComponents?, now: Date = Date()) -> Bool {
        guard let comps else { return false }
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return false }
        let endOfTomorrow = cal.date(byAdding: DateComponents(day: 2, second: -1),
                                     to: cal.startOfDay(for: now))!
        return date <= endOfTomorrow
    }

    /// Due by the end of today — i.e. actually today's problem. Overdue
    /// counts; anything later does not. Used to hold the eye on today's
    /// work while tomorrow's stays visible but quiet.
    public static func isDueToday(_ reminder: EKReminder, now: Date = Date()) -> Bool {
        isDueToday(due: reminder.dueDateComponents, now: now)
    }

    public static func isDueToday(due comps: DateComponents?, now: Date = Date()) -> Bool {
        guard let comps else { return false }
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return false }
        let endOfToday = cal.date(byAdding: DateComponents(day: 1, second: -1),
                                  to: cal.startOfDay(for: now))!
        return date <= endOfToday
    }

    /// Today's reminders — due today or earlier — grouped by the list
    /// they live in, in the same shape the detailed view's multi-list
    /// layout uses. Simple mode shows this down its left side.
    ///
    /// Built from `reminders` (the Today fetch), NOT from
    /// `groupedReminders`. The grouped fetch deliberately has no
    /// due-date predicate — it's the "show me these lists" display — so
    /// reusing it here would quietly put next month's reminders on
    /// screen under a heading that says today. Every item is re-checked
    /// with `isDueToday` anyway, so the filter holds even if the
    /// underlying fetch ever widens.
    ///
    /// `preferredOrder` is the user's configured list order, so the
    /// groups read in the same sequence as the detailed view. Lists that
    /// aren't in it still appear — a reminder due today is never hidden
    /// because its list wasn't picked for the detailed view — they just
    /// sort after, alphabetically.
    public func todayGroupedByList(preferredOrder: [String] = []) -> [ReminderListGroup] {
        let due = reminders.filter { Self.isDueToday($0) }
        var byList: [String: [EKReminder]] = [:]
        for reminder in due {
            byList[reminder.calendar?.title ?? "Reminders", default: []].append(reminder)
        }
        return Self.orderedListNames(Array(byList.keys), preferred: preferredOrder)
            .map { ReminderListGroup(id: $0, name: $0, reminders: byList[$0] ?? []) }
    }

    /// Preferred names first, in their given order; everything else
    /// after, alphabetically. Split out from `todayGroupedByList` so the
    /// ordering rule is testable without an EventKit store.
    public static func orderedListNames(_ names: [String], preferred: [String]) -> [String] {
        let present = Set(names)
        let head = preferred.filter { present.contains($0) }
        let tail = names.filter { !head.contains($0) }.sorted()
        return head + tail
    }

    public func toggleComplete(_ reminder: EKReminder) {
        reminder.isCompleted.toggle()
        try? store.save(reminder, commit: true)
        fetchReminders()
    }
}
