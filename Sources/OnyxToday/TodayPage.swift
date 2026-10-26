//
// TodayPage.swift
//
// Responsibility: Onyx Today's one page — the Timing tiles at the top,
//                 then the agenda (reminders or the calendar), open PRs and
//                 tracked pipelines — built from the same section views
//                 the Mac's simple mode shows in its side panel.
// Scope: The iPhone app's content; the iPad shows it as one of its views.
//
// The Mac lays these sections out as a column beside its charts with the
// tiles in the bottom strip; here they are one long page with the tiles on
// top (docs/ios-plan.md). The sections are the Mac's own views (OnyxUI);
// only the arrangement is this file's. A wide screen — landscape, an iPad,
// an unfolded phone — gets two columns of the same sections.
//

import SwiftUI
import OnyxCore
import OnyxUI

public struct TodayRoot: View {
    @ObservedObject var model: TodayModel

    public init(model: TodayModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.home == nil {
                PairingView(model: model)
            } else {
                TodayPage(model: model)
            }
        }
        .preferredColorScheme(.dark)
    }
}

public struct TodayPage: View {
    @ObservedObject var model: TodayModel
    @ObservedObject private var timing: TimingManager
    @ObservedObject private var reminders: RemindersManager
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingSettings = false

    public init(model: TodayModel) {
        self.model = model
        self._timing = ObservedObject(wrappedValue: model.today.timing)
        self._reminders = ObservedObject(wrappedValue: model.today.reminders)
    }

    private var today: TodayState { model.today }
    private var accent: Color { today.accentColor }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                tiles
                if sizeClass == .regular {
                    HStack(alignment: .top, spacing: 32) {
                        agenda.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 26) {
                            pullRequests
                            pipelines
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    agenda
                    pullRequests
                    pipelines
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable {
            SharedStateSync.shared.syncNow()
            TodayState.refreshServices()
            reminders.fetchReminders()
        }
        .background(Color.black.ignoresSafeArea())
        // A phone is read at arm's length, not across a room: a little
        // larger than the Mac's design sizes.
        .environment(\.monitorFontScale, 1.2)
        .sheet(isPresented: $showingSettings) {
            TodaySettingsView(model: model)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .monitorFont(size: 12, weight: .medium)
                    .foregroundColor(accent)
                    .tracking(2)
                Text(model.syncStatusLine)
                    .monitorFont(size: 9)
                    .foregroundColor(model.syncFailed ? Color.onyxRed.opacity(0.8) : .gray.opacity(0.5))
                    .lineLimit(2)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(.gray.opacity(0.7))
            }
            .accessibilityLabel("Settings")
        }
    }

    /// The week's hours, one tile per Timing project, then the agents'.
    @ViewBuilder
    private var tiles: some View {
        let hasTiles = timing.isConfigured || timing.agents != nil
        if hasTiles {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if timing.isConfigured {
                        ForEach(timing.groups) { group in
                            WeeklyTimingTile(group: group, showsTitle: timing.groups.count > 1,
                                             accentColor: accent)
                        }
                    }
                    if let agents = timing.agents {
                        WeeklyTimingTile(group: agents, accentColor: accent, isAgents: true)
                    }
                    SimpleRemindersScope(reminders: reminders)
                }
            }
        } else {
            SimpleRemindersScope(reminders: reminders)
        }
    }

    @ViewBuilder
    private var agenda: some View {
        if today.settings.agendaPane == .calendar {
            SimpleTodayCalendar(today: today)
        } else {
            SimpleTodayReminders(today: today, reminders: reminders, accentColor: accent,
                                 listOrder: today.settings.remindersLists)
        }
    }

    private var pullRequests: some View {
        SimplePullRequests(today: today, accentColor: accent)
    }

    @ViewBuilder
    private var pipelines: some View {
        let tracked = today.workflows.pipelines.count + today.gitLabPipelines.pipelines.count
        if tracked > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("PIPELINES")
                    .monitorFont(size: 10, weight: .medium)
                    .foregroundColor(accent)
                    .tracking(2)
                ScrollView(.horizontal, showsIndicators: false) {
                    SimplePipelinesStrip()
                }
            }
        }
    }
}
