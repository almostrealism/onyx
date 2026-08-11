import SwiftUI
import EventKit

/// A group of reminders under one list name
public struct ReminderListGroup: Identifiable {
    public let id: String   // list name
    public let name: String
    public let reminders: [EKReminder]
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

    public func toggleComplete(_ reminder: EKReminder) {
        reminder.isCompleted.toggle()
        try? store.save(reminder, commit: true)
        fetchReminders()
    }
}


struct RemindersSection: View {
    @ObservedObject var appState: AppState
    @StateObject private var reminders = RemindersManager()
    @ObservedObject private var flowtree = FlowtreeManager.shared

    /// `R` while the overlay is up narrows every list to what's due by end
    /// of tomorrow. Filtering happens here rather than in the fetch so the
    /// toggle is instant and the list grouping is untouched.
    private var dueSoonOnly: Bool { appState.appearance.remindersDueSoonOnly }

    private func visible(_ list: [EKReminder]) -> [EKReminder] {
        dueSoonOnly ? list.filter { RemindersManager.isDueSoon($0) } : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(reminders.displayName)
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(appState.accentColor)
                    .tracking(2)

                // Say WHY the list is short — a silently filtered list
                // reads as missing reminders.
                if dueSoonOnly {
                    Text("DUE ≤ TMRW")
                        .monitorFont(size: 8, weight: .bold)
                        .foregroundColor(Color.onyxAmber)
                        .tracking(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.onyxAmber.opacity(0.15))
                        .cornerRadius(3)
                        .help("Showing only reminders due today or tomorrow — press R to show all")
                }

                Spacer()

                let total = dueSoonOnly
                    ? visible(reminders.reminders).count
                    : reminders.totalCount
                if total > 0 {
                    Text("\(total)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.4))
                }
            }

            // Transient result of a flowtree submit (auto-clears).
            if let status = flowtree.submitStatus {
                Text(status.message)
                    .monitorFont(size: 10)
                    .foregroundColor(status.isError ? Color.onyxRed : Color.onyxGreen)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Scope indicator — totals across ALL lists regardless of
            // what's displayed: how much is due now, and how much larger
            // that gets by tomorrow.
            if reminders.accessGranted {
                HStack(spacing: 8) {
                    scopeWidget(count: reminders.dueTodayCount,
                                label: "today", color: Color.onyxRed)
                    scopeWidget(count: reminders.dueTomorrowCount,
                                label: "by tmrw", color: Color.onyxAmber)
                    Spacer(minLength: 0)
                }
            }

            if !reminders.accessGranted {
                Text("Reminders access not granted")
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.4))
            } else if reminders.isMultiList {
                // Grouped display: single column. We used to lay out
                // two columns when the section had the full overlay
                // width, but the overlay now reserves the right half
                // for Open PRs / Pipelines so reminders only get the
                // left half — not enough room for two columns of titles.
                // Filter within each list so the grouping the user set up
                // survives; lists left empty by the filter drop out.
                let nonEmpty = reminders.groupedReminders
                    .map { ReminderListGroup(id: $0.id, name: $0.name,
                                             reminders: visible($0.reminders)) }
                    .filter { !$0.reminders.isEmpty }
                if nonEmpty.isEmpty {
                    Text(dueSoonOnly ? "Nothing due today or tomorrow" : reminders.emptyMessage)
                        .monitorFont(size: 11)
                        .foregroundColor(.gray.opacity(0.3))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(nonEmpty, id: \.id) { group in
                            ReminderListColumn(group: group, appState: appState,
                                               reminders: reminders,
                                               dimNotToday: dueSoonOnly)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if visible(reminders.reminders).isEmpty {
                Text(dueSoonOnly ? "Nothing due today or tomorrow" : reminders.emptyMessage)
                    .monitorFont(size: 11)
                    .foregroundColor(.gray.opacity(0.3))
            } else {
                // Single list or Today: flat display
                let shown = visible(reminders.reminders)
                ForEach(Array(shown.prefix(14)), id: \.calendarItemIdentifier) { reminder in
                    ReminderRow(reminder: reminder, appState: appState, manager: reminders,
                                // In due-soon mode, tomorrow's work stays
                                // visible but recedes — today is the point.
                                deemphasized: dueSoonOnly
                                    && !RemindersManager.isDueToday(reminder))
                }
                if shown.count > 14 {
                    Text("+\(shown.count - 14) more")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.3))
                }
            }
        }
        .onAppear {
            reminders.selectedLists = appState.appearance.remindersLists
            reminders.fetchReminders()
        }
        .onChange(of: appState.appearance.remindersLists) { _, newValue in
            reminders.selectedLists = newValue
            reminders.fetchReminders()
        }
    }

    /// One count + label chip for the scope indicator.
    private func scopeWidget(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .monitorFont(size: 11, weight: .medium)
                .foregroundColor(color)
            Text(label)
                .monitorFont(size: 9)
                .foregroundColor(.gray.opacity(0.5))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}

private struct ReminderListColumn: View {
    let group: ReminderListGroup
    @ObservedObject var appState: AppState
    let reminders: RemindersManager
    /// Fade anything that isn't today's problem (due-soon mode only).
    var dimNotToday: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.name.uppercased())
                .monitorFont(size: 9, weight: .medium)
                .foregroundColor(appState.accentColor.opacity(0.6))
                .tracking(1)

            let visible = Array(group.reminders.prefix(14))
            ForEach(visible, id: \.calendarItemIdentifier) { reminder in
                ReminderRow(reminder: reminder, appState: appState, manager: reminders,
                            deemphasized: dimNotToday
                                && !RemindersManager.isDueToday(reminder))
            }
            if group.reminders.count > 14 {
                Text("+\(group.reminders.count - 14) more")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.3))
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: EKReminder
    @ObservedObject var appState: AppState
    let manager: RemindersManager
    /// Due later than today while the due-soon filter is on: keep it
    /// readable, but stop it competing with what's due now.
    var deemphasized: Bool = false
    @ObservedObject private var flowtree = FlowtreeManager.shared
    @ObservedObject private var flowtreeConfig = FlowtreeConfigStore.shared
    @State private var isHovering = false

    private var showSubmit: Bool { isHovering && !reminder.isCompleted }

    /// Tomorrow's items are context, not today's work: legible, but a
    /// clear step back from the rows you're meant to be looking at.
    /// Hovering restores full strength, so reading one is never a fight.
    private var titleColor: Color {
        if reminder.isCompleted { return .gray.opacity(0.3) }
        if deemphasized && !isHovering { return .white.opacity(0.4) }
        return .white.opacity(0.8)
    }

    private func dueColor(_ due: DateComponents) -> Color {
        if isReminderOverdue(due) && !reminder.isCompleted { return Color.onyxRed }
        if deemphasized && !isHovering { return .gray.opacity(0.22) }
        return .gray.opacity(0.4)
    }

    private var checkboxColor: Color {
        if reminder.isCompleted { return appState.accentColor }
        if deemphasized && !isHovering { return .gray.opacity(0.22) }
        return .gray.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { manager.toggleComplete(reminder) }) {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .monitorFont(size: 12, design: .default)
                    .foregroundColor(checkboxColor)
            }
            .buttonStyle(.plain)

            Text(reminder.title ?? "Untitled")
                .monitorFont(size: 12)
                .foregroundColor(titleColor)
                .strikethrough(reminder.isCompleted)
                .lineLimit(1)

            Spacer()

            // Submit-to-flowtree affordance, revealed on hover. Opacity (not a
            // conditional) so the row layout doesn't jump and the menu isn't
            // dismissed when the label fades as the pointer moves onto it.
            submitMenu
                .opacity(showSubmit ? 1 : 0)
                .allowsHitTesting(showSubmit)

            if let due = reminder.dueDateComponents, let label = dueLabel(due) {
                Text(label)
                    .monitorFont(size: 10)
                    .foregroundColor(dueColor(due))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 2)
        // Whole-row hit region so hover fires anywhere on the row — including
        // the trailing area where the submit button renders. Without this the
        // trigger is only the title glyphs, which don't overlap the button.
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { flowtree.ensureLoaded() }   // warm the picker
        }
    }

    /// Paper-plane menu: pick a workstream to submit this reminder to, or a
    /// prompt to configure the endpoint when none is set.
    @ViewBuilder
    private var submitMenu: some View {
        Menu {
            if !flowtreeConfig.isConfigured {
                Button("Configure Flowtree endpoint…") { appState.showSettings = true }
            } else if flowtree.workstreams.isEmpty {
                if flowtree.isLoading {
                    Text("Loading workstreams…")
                } else if let err = flowtree.lastError {
                    Text(err)
                    Button("Retry") { flowtree.refresh() }
                } else {
                    Text("No workstreams found")
                    Button("Refresh") { flowtree.refresh() }
                }
            } else {
                Text("Submit “\(reminder.title ?? "reminder")” to…")
                ForEach(flowtree.workstreams) { ws in
                    Button {
                        Task { await flowtree.submit(reminder: reminder, to: ws) }
                    } label: {
                        Text(ws.subtitle.map { "\(ws.displayName)  —  \($0)" } ?? ws.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "paperplane")
                .monitorFont(size: 11, design: .default)
                .foregroundColor(appState.accentColor.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Submit this reminder to a flowtree workstream")
    }

    /// Compact due-date string for the trailing slot. Shows the time when
    /// the reminder has one, and the day whenever it isn't today, so
    /// list-mode reminders (which can be due on any date) are
    /// distinguishable: "15:00" today, "Tmrw", "Mon 9:00", "Jun 10".
    private func dueLabel(_ comps: DateComponents) -> String? {
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return nil }
        let hasTime = comps.hour != nil && comps.minute != nil
        let timeStr = hasTime ? String(format: "%d:%02d", comps.hour!, comps.minute!) : nil

        let dayDiff = cal.dateComponents([.day],
                                         from: cal.startOfDay(for: Date()),
                                         to: cal.startOfDay(for: date)).day ?? 0
        let dayStr: String?
        switch dayDiff {
        case 0:  dayStr = nil               // today — the time alone is enough
        case 1:  dayStr = "Tmrw"
        case -1: dayStr = "Yest"
        case 2..<7:  dayStr = Self.weekdayFormatter.string(from: date)
        default: dayStr = Self.monthDayFormatter.string(from: date)
        }

        switch (dayStr, timeStr) {
        case let (day?, time?): return "\(day) \(time)"
        case let (day?, nil):   return day
        case let (nil, time?):  return time
        case (nil, nil):        return "Today"   // due today, no time set
        }
    }

    private func isReminderOverdue(_ comps: DateComponents) -> Bool {
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return false }
        // With a time, compare instants. All-day reminders are only
        // overdue once the whole day has passed — midnight-today is not
        // "overdue" just because the current clock time is later.
        if comps.hour != nil && comps.minute != nil { return date < Date() }
        return cal.startOfDay(for: date) < cal.startOfDay(for: Date())
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
}
