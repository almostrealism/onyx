//
// TodayReminders.swift
//
// Responsibility: Today's reminders, and the due-today / due-tomorrow
//                 counts. Shared by the Mac and the iPhone.
//
import SwiftUI
import EventKit
import OnyxCore

/// Today's reminders, listed down the left of simple mode.
///
/// Deliberately austere: simple mode is the across-the-room view, so this
/// answers one question — what am I doing today — and stops. No lists, no
/// per-item metadata beyond a time, and a hard cap with a "+N more" so a
/// heavy day can't push the charts around.
///
/// The manager backing simple mode runs in "Today" mode (no selected
/// lists), so `reminders.reminders` is already exactly what's due by end
/// of today, overdue included, across every list.
public struct SimpleTodayReminders: View {
    @ObservedObject var today: TodayState
    @ObservedObject var reminders: RemindersManager
    let accentColor: Color
    /// The user's configured list order, so the groups read in the same
    /// sequence as the detailed overlay.
    let listOrder: [String]

    public init(today: TodayState, reminders: RemindersManager, accentColor: Color, listOrder: [String]) {
        self._today = ObservedObject(wrappedValue: today)
        self._reminders = ObservedObject(wrappedValue: reminders)
        self.accentColor = accentColor
        self.listOrder = listOrder
    }
    @Environment(\.monitorFontScale) private var fontScale

    /// Enough to be useful, few enough to stay readable at a distance.
    /// Counted across every group, not per group — three lists of five
    /// is still fifteen lines of text on a wall-mounted display.
    private let maxShown = 10

    public var body: some View {
        let groups = reminders.todayGroupedByList(preferredOrder: listOrder)
        let total = groups.reduce(0) { $0 + $1.reminders.count }
        // Fill groups in order until the budget runs out, then drop the
        // rest. Truncating the LAST visible group rather than every group
        // keeps the earlier lists — the ones the user ordered first —
        // complete.
        var budget = maxShown
        var shown: [ReminderListGroup] = []
        for group in groups where budget > 0 {
            let take = Array(group.reminders.prefix(budget))
            budget -= take.count
            shown.append(ReminderListGroup(id: group.id, name: group.name, reminders: take))
        }

        return VStack(alignment: .leading, spacing: 9) {
            AgendaPaneTabs(today: today, remindersTitle: "TODAY")
            FeatureTipLine(place: .monitorAgenda, accent: accentColor)

            ForEach(shown, id: \.id) { group in
                VStack(alignment: .leading, spacing: 5) {
                    // One list gets no heading — the same rule the
                    // detailed view follows, where grouping only appears
                    // once there's more than one list to tell apart.
                    if shown.count > 1 {
                        Text(group.name.uppercased())
                            .monitorFont(size: 9, weight: .medium)
                            .foregroundColor(accentColor.opacity(0.6))
                            .tracking(1)
                    }

                    ForEach(group.reminders, id: \.calendarItemIdentifier) { reminder in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            // Overdue is the only distinction worth making here.
                            Circle()
                                .fill(isOverdue(reminder) ? Color.onyxRed : accentColor.opacity(0.55))
                                .frame(width: 5, height: 5)
                            Text(reminder.title ?? "Untitled")
                                .monitorFont(size: 13)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            if let time = timeLabel(reminder) {
                                Text(time)
                                    .monitorFont(size: 10)
                                    .foregroundColor(.gray.opacity(0.45))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
            }

            if total > maxShown {
                Text("+\(total - maxShown) more")
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.35))
            }
        }
    }

    /// A time only when the reminder has one — an all-day item shows
    /// nothing rather than a meaningless 00:00.
    private func timeLabel(_ reminder: EKReminder) -> String? {
        guard let c = reminder.dueDateComponents,
              let hour = c.hour, let minute = c.minute else { return nil }
        return String(format: "%d:%02d", hour, minute)
    }

    private func isOverdue(_ reminder: EKReminder) -> Bool {
        guard let c = reminder.dueDateComponents,
              let date = Calendar.current.date(from: c) else { return false }
        if c.hour != nil && c.minute != nil { return date < Date() }
        // All-day: only overdue once the whole day has passed.
        return Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
    }
}

/// Simple-mode reminders scope: the same due-today / due-by-tomorrow
/// totals shown above the full reminders list, but standalone (no list)
/// so the two numbers stay visible at a glance in the stripped-down view.
/// Empty (zero-height) until Reminders access is granted.
public struct SimpleRemindersScope: View {
    @ObservedObject var reminders: RemindersManager

    public init(reminders: RemindersManager) {
        self._reminders = ObservedObject(wrappedValue: reminders)
    }

    public var body: some View {
        if reminders.accessGranted {
            HStack(spacing: 8) {
                chip(reminders.dueTodayCount, "today", Color.onyxRed)
                chip(reminders.dueTomorrowCount, "by tmrw", Color.onyxAmber)
            }
        } else {
            EmptyView()
        }
    }

    private func chip(_ count: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .monitorFont(size: 13, weight: .medium)
                .foregroundColor(color)
            Text(label)
                .monitorFont(size: 9)
                .foregroundColor(.gray.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
