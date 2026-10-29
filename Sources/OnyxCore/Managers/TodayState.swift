//
// TodayState.swift
//
// Responsibility: Everything the Today sections read — Timing and agent
//                 hours, today's reminders and calendar, open PRs and their
//                 CI, tracked pipelines — and the settings that shape them.
// Scope: Per window on the Mac (AppState holds one); the whole app on the
//        iPhone, where there is no AppState (docs/ios-plan.md).
// Threading: Main thread, like the managers it holds.
//
// The Today sections used to take the whole AppState, which also owns
// terminals, connection pairs and the MCP server; nothing on a phone can
// have those. This is the part they actually read. A Today section reads
// from here and never from AppState, so whatever appears in it on the Mac
// appears on the phone without anyone remembering to port it.
//
// Settings are read straight from AppearanceStore rather than copied:
// there is one source of truth, and the Mac's Settings window, the key
// handlers and this all write to the same place.
//

import Foundation
import Combine
import SwiftUI

public final class TodayState: ObservableObject {

    /// The window this belongs to, for the settings that are per window
    /// (accent, Timing's project filter). 0 on the phone.
    public let windowIndex: Int

    private let appearanceStore = AppearanceStore.shared
    private var cancellables: Set<AnyCancellable> = []

    public init(windowIndex: Int) {
        self.windowIndex = windowIndex
        // The Today settings live in the appearance config: when it
        // changes, anything drawn from it may have.
        appearanceStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Which calendars the agenda pane draws from. `$config` delivers
        // the new value; objectWillChange fires before it's set.
        appearanceStore.$config
            .map { Set($0.hiddenCalendars) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { TodayCalendarStore.shared.setHidden($0) }
            .store(in: &cancellables)
    }

    // MARK: - What the sections show

    /// Timing.app hours, and agent hours from the flowtree controller.
    public lazy var timing: TimingManager = {
        let t = TimingManager(windowIndex: windowIndex)
        t.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        return t
    }()

    /// Today's reminders across every list ("Today" mode: no selected
    /// lists). Lazy because creating one asks for Reminders access, which
    /// should happen when a Today section first appears, not at launch.
    public lazy var reminders = RemindersManager()

    /// Today's calendar.
    public var calendar: TodayCalendarStore { .shared }

    /// GitHub PRs, GitLab MRs and the CI runs on them.
    public var pullRequests: PullRequestManager { .shared }
    public var mergeRequests: GitLabMergeRequestManager { .shared }
    public var prPipelines: PRPipelineMonitor { .shared }

    /// Tracked pipelines (GitHub workflows and GitLab pipelines).
    public var workflows: WorkflowMonitor { .shared }
    public var gitLabPipelines: GitLabPipelineMonitor { .shared }

    // MARK: - Starting

    /// Start the services the Today sections show: Timing and agent
    /// hours, PRs and their CI, tracked pipelines. The Mac starts these as
    /// part of its own launch; an app that is only Today calls this.
    public static func startServices() {
        TimingDataStore.shared.startPolling()
        AgentTimeStore.shared.startPolling()
        PullRequestManager.shared.startPolling()
        WorkflowMonitor.shared.startPolling()
        GitLabMergeRequestManager.shared.startPolling()
        GitLabPipelineMonitor.shared.startPolling()
        PRPipelineMonitor.shared.start(following:
            Publishers.CombineLatest(PullRequestManager.shared.$pullRequests,
                                     GitLabMergeRequestManager.shared.$mergeRequests)
                .map { $0 + $1 }
                .eraseToAnyPublisher())
    }

    /// Ask every service for fresh data now — after the settings or the
    /// tokens changed, or when the app comes back to the front.
    public static func refreshServices() {
        PullRequestManager.shared.refresh()
        GitLabMergeRequestManager.shared.refresh()
        WorkflowMonitor.shared.refresh()
        GitLabPipelineMonitor.shared.refresh()
    }

    // MARK: - Settings

    public var settings: AppearanceConfig { appearanceStore.config }

    /// This window's accent: its own, or the global one.
    public var accentHex: String {
        settings.windowAccents[windowIndex] ?? settings.accentHex
    }

    public var accentColor: Color { Color(hex: accentHex) }

    /// Called after `setAgendaPane`, for what the platform does around it —
    /// on the Mac, simple mode opens its side panel so the switch is seen.
    public var onAgendaPaneSet: ((AgendaPane) -> Void)?

    /// Show Reminders or today's calendar in the agenda pane.
    public func setAgendaPane(_ pane: AgendaPane) {
        appearanceStore.config.agendaPane = pane
        onAgendaPaneSet?(pane)
        appearanceStore.save()
        FeatureTipStore.shared.used("monitor.calendar")
    }

    // MARK: - Open PRs

    /// GitHub PRs and GitLab MRs together, without the drafts the user
    /// filtered out — the same list every layout shows, so no two can
    /// disagree about which PRs are yours.
    public func visiblePullRequests() -> [PullRequest] {
        Self.visible(pullRequests.pullRequests + mergeRequests.mergeRequests,
                     filter: settings.prDraftFilter)
    }

    /// The visible PRs, most interesting first (see `PRInterest`).
    public func orderedPullRequests() -> [PullRequest] {
        Self.ordered(visiblePullRequests()) { prPipelines.runs(for: $0) }
    }

    static func visible(_ prs: [PullRequest], filter: PRDraftFilter) -> [PullRequest] {
        prs.filter { filter.keeps($0) }
    }

    /// How interesting a PR is at a glance, lowest first.
    ///
    /// Today answers one question — what is happening — so a PR with
    /// something in flight outranks one that is merely broken, and a broken
    /// one outranks one that is finished and green. A green PR needs
    /// nothing from you, which is exactly why it goes last and is the first
    /// to be dropped when the list overflows.
    public enum PRInterest: Int, Comparable {
        case busy = 0        // something running or queued
        case failing = 1     // nothing in flight, but something is red
        case settled = 2     // finished, nothing failing

        public static func < (a: PRInterest, b: PRInterest) -> Bool { a.rawValue < b.rawValue }

        public static func of(_ runs: [PRPipelineRun]) -> PRInterest {
            if PRPipelineRun.mostRecentlyActive(runs) != nil { return .busy }
            if runs.contains(where: \.needsAttention) { return .failing }
            return .settled
        }
    }

    /// Busy PRs first — most recently busy at the top — then failing
    /// ones, then the settled ones. Within a tier the forge's own order
    /// is kept, so the list doesn't reshuffle on every poll.
    public static func ordered(_ prs: [PullRequest],
                               runs: (PullRequest) -> [PRPipelineRun]) -> [PullRequest] {
        prs.enumerated().sorted { a, b in
            let (ra, rb) = (runs(a.element), runs(b.element))
            let (ia, ib) = (PRInterest.of(ra), PRInterest.of(rb))
            if ia != ib { return ia < ib }
            // Inside the busy tier, the newest thing to have started or
            // been queued is the one worth reading first.
            if ia == .busy,
               let sa = PRPipelineRun.mostRecentlyActive(ra)?.activeJob?.since,
               let sb = PRPipelineRun.mostRecentlyActive(rb)?.activeJob?.since,
               sa != sb {
                return sa > sb
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}
