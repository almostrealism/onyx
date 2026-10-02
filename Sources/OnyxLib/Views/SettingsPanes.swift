//
// SettingsPanes.swift
//
// Responsibility: The Settings sidebar, and the Reminders pane.
// Scope: Presentation. Which settings live in which pane is SettingsView's
//        business; the list-order operations are ReminderListOrder's.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar

/// The category list down the left of Settings — one row per pane, the
/// chosen one highlighted, as in macOS's System Settings.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    let accent: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .light, design: .monospaced))
                    .foregroundColor(Color.onyxBlue)
                    .tracking(4)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)

                ForEach(SettingsPane.allCases) { pane in
                    SettingsSidebarRow(pane: pane, selected: pane == selection, accent: accent) {
                        selection = pane
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 20)
        }
        .frame(width: 196)
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                    .foregroundColor(selected ? accent : .gray.opacity(0.7))
                Text(pane.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(selected ? .white : .white.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? accent.opacity(0.22)
                          : (hovering ? Color.white.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Reminders

/// Which Reminders lists the monitor shows, and in what order.
///
/// The order used to be whatever order you happened to choose them in, so
/// changing it meant removing every list and adding them back one at a
/// time. Here the chosen lists are shown in the order the monitor will
/// draw them, and can be dragged into a new one — or nudged with the
/// arrows, for anyone who'd rather not drag.
struct RemindersSettingsPane: View {
    @ObservedObject var appState: AppState
    @ObservedObject var reminders: RemindersManager
    @State private var dragging: String?

    private var accent: Color { Color(hex: appState.appearance.accentHex) }

    private var lists: [String] { appState.appearance.remindersLists }

    private func update(_ f: ([String]) -> [String]) {
        appState.appearance.remindersLists = f(appState.appearance.remindersLists)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !reminders.accessGranted {
                VStack(alignment: .leading, spacing: 6) {
                    header("REMINDERS")
                    Text("Onyx doesn't have access to Reminders. Allow it in System Settings → Privacy & Security → Reminders, then reopen Settings.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                shownSection
                hiddenSection
            }
        }
    }

    // MARK: Shown, in order

    private var shownSection: some View {
        let rows = ReminderListOrder.shown(lists, available: reminders.availableLists)
        return VStack(alignment: .leading, spacing: 6) {
            header("ON THE MONITOR, IN THIS ORDER")

            if rows.isEmpty {
                Text("No lists chosen, so the monitor shows TODAY: everything due today, across all your lists. Add a list below to show it by name instead.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                Text("Drag to reorder, or use the arrows.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))

                VStack(spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.element.name) { index, row in
                        shownRow(row, index: index, count: rows.count)
                            .onDrag {
                                dragging = row.name
                                return NSItemProvider(object: row.name as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(
                                target: row.name,
                                dragging: $dragging,
                                move: { name, target in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        update { ReminderListOrder.move(name, to: target, in: $0) }
                                    }
                                }
                            ))
                    }
                }
                // A drop between rows, or on the list's padding, still
                // ends the drag — otherwise the dragged row stays lit.
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                    dragging = nil
                    return true
                }
            }
        }
        .onDisappear { dragging = nil }
    }

    private func shownRow(_ row: ReminderListOrder.Row, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.gray.opacity(0.6))
                .help("Drag to reorder")

            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray.opacity(0.6))
                .frame(width: 16, alignment: .trailing)

            Text(row.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(row.missing ? .gray.opacity(0.6) : .white)
                .strikethrough(row.missing, color: .gray.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            if row.missing {
                Text("not in Reminders")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color.onyxAmber)
                    .help("No list by this name exists any more — renamed or deleted. Remove it, or it will reappear if the list comes back.")
            }

            Spacer(minLength: 8)

            iconButton("chevron.up", help: "Move up", enabled: index > 0) {
                update { ReminderListOrder.nudge(row.name, by: -1, in: $0) }
            }
            iconButton("chevron.down", help: "Move down", enabled: index < count - 1) {
                update { ReminderListOrder.nudge(row.name, by: 1, in: $0) }
            }
            iconButton("minus.circle", help: "Stop showing this list", enabled: true) {
                update { ReminderListOrder.remove(row.name, from: $0) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(dragging == row.name ? accent.opacity(0.25) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(dragging == row.name ? accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: Not shown

    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = ReminderListOrder.hidden(lists, available: reminders.availableLists)
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header("NOT SHOWN")
                VStack(spacing: 4) {
                    ForEach(hidden, id: \.self) { name in
                        HStack(spacing: 10) {
                            Text(name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button(action: { update { ReminderListOrder.add(name, to: $0) } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9))
                                    Text("Show")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .foregroundColor(accent)
                            }
                            .buttonStyle(.plain)
                            .help("Add to the end of the list above")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// The blue small-caps header most of Settings uses.
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(Color.onyxBlue.opacity(0.7))
            .tracking(2)
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(enabled ? .white.opacity(0.7) : .gray.opacity(0.25))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

/// Live reordering while dragging: as the dragged row passes over another,
/// it takes that row's place, so the list shows the result before you let
/// go. The drop itself only ends the drag.
private struct ReorderDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let name = dragging, name != target else { return }
        move(name, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
