//
// ReminderListOrder.swift
//
// Responsibility: Editing the ordered list of Reminders lists the monitor
//                 shows (`AppearanceConfig.remindersLists`).
// Scope: Pure functions over [String]. The order of the array IS the order
//        on screen; an empty array means "Today" (everything due today,
//        across all lists).
//
// The only way to order these used to be choosing them in the order you
// wanted them, so changing the order meant removing every list and adding
// them back one by one. These are the operations the Reminders pane offers
// in its place: move one, nudge one up or down, add, remove.
//

import Foundation

public enum ReminderListOrder {

    /// One row of the "shown" list.
    public struct Row: Equatable, Sendable {
        public let name: String
        /// Chosen, but no list by that name exists in Reminders any more:
        /// renamed or deleted. Kept so the user can see it and remove it,
        /// rather than having it silently vanish and reappear if the list
        /// comes back.
        public let missing: Bool
    }

    /// The chosen lists, in display order, each marked if it no longer exists.
    public static func shown(_ selected: [String], available: [String]) -> [Row] {
        let existing = Set(available)
        return selected.map { Row(name: $0, missing: !existing.contains($0)) }
    }

    /// The lists that exist and aren't chosen, alphabetically.
    public static func hidden(_ selected: [String], available: [String]) -> [String] {
        let chosen = Set(selected)
        return available.filter { !chosen.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Move `name` so it sits where `target` is now. Dragging a row onto
    /// another row puts it in that row's place, and everything between
    /// shifts by one. Unknown names leave the order alone.
    public static func move(_ name: String, to target: String, in lists: [String]) -> [String] {
        guard name != target,
              let from = lists.firstIndex(of: name),
              let to = lists.firstIndex(of: target) else { return lists }
        var out = lists
        out.remove(at: from)
        out.insert(name, at: to)
        return out
    }

    /// Move `name` one place earlier (`by: -1`) or later (`by: 1`). Clamped
    /// at both ends.
    public static func nudge(_ name: String, by delta: Int, in lists: [String]) -> [String] {
        guard let from = lists.firstIndex(of: name) else { return lists }
        let to = max(0, min(lists.count - 1, from + delta))
        guard to != from else { return lists }
        var out = lists
        out.remove(at: from)
        out.insert(name, at: to)
        return out
    }

    /// Show `name`, at the end. Already shown → unchanged.
    public static func add(_ name: String, to lists: [String]) -> [String] {
        lists.contains(name) ? lists : lists + [name]
    }

    /// Stop showing `name`. Removing the last one returns to Today mode.
    public static func remove(_ name: String, from lists: [String]) -> [String] {
        lists.filter { $0 != name }
    }
}
