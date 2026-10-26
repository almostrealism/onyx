import SwiftUI
import EventKit
import OnyxCore
import OnyxUI

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
                AgendaPaneTabs(today: appState.today, remindersTitle: reminders.displayName)

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

            FeatureTipLine(place: .monitorAgenda, accent: appState.accentColor)

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
                                             reminders: visible($0.reminders))
                    }
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
