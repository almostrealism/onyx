//
// MonitorStrip.swift
//
// Responsibility: Turning each kind of workload into strip candidates
//                 that report their own priority, and choosing which of
//                 them get the bottom strip's few slots, in what order.
// Scope: Service. Pure functions over Models: a source is a snapshot of
//        its data, the ranker has no state of its own (the view hands it
//        what was on screen last time), so every decision is testable.
//
// Adding a kind of workload: a case in MonitorStripItem.Content, a source
// here that says what each item is worth, and a pill to draw it. Nothing
// else changes — the ranker doesn't know what any item is.
//

import Foundation

/// Something that can put items in the strip.
public protocol MonitorStripSource {
    /// This source's candidates, each with its priority — which may
    /// depend on what else is on screen.
    func items(in context: MonitorStripContext) -> [MonitorStripItem]
}

// MARK: - Sources

/// Containers, worth their CPU: half a core is 0.5.
public struct ContainerStripSource: MonitorStripSource {
    public let loads: [ContainerLoad]

    /// Keeps an idle container eligible for a slot nothing else wants —
    /// an empty strip says less than a quiet container does — while
    /// everything with a real priority outranks it.
    static let idleFloor = 0.0001

    public init(loads: [ContainerLoad]) { self.loads = loads }

    public func items(in context: MonitorStripContext) -> [MonitorStripItem] {
        loads.map {
            MonitorStripItem(id: "container:\($0.name)",
                             priority: max(Self.idleFloor, $0.cpuPercent / 100),
                             content: .container($0))
        }
    }
}

/// One item per PR whose CI has a job running or queued: the job it most
/// recently started or queued, the one the side panel shows.
public struct PRJobStripSource: MonitorStripSource {
    /// A running job is something you're waiting on, so it outranks a
    /// container ticking over — but a container doing real work (a third
    /// of a core or more) is more urgent still.
    public static let priority = 0.3

    /// Busiest-first, as the side panel orders them — so with more busy
    /// PRs than slots, the ones that started most recently win.
    public let activities: [PRJobActivity]

    public init(activities: [PRJobActivity]) { self.activities = activities }

    /// The activities for `prs`, in the order given, skipping PRs with
    /// nothing in flight.
    public init(prs: [PullRequest], runs: (PullRequest) -> [PRPipelineRun]) {
        activities = prs.compactMap { pr in
            guard let run = PRPipelineRun.mostRecentlyActive(runs(pr)),
                  let job = run.activeJob else { return nil }
            return PRJobActivity(prID: pr.id, branch: Self.branchLabel(pr), prTitle: pr.title,
                                 prURL: pr.url, workflow: run.name,
                                 job: job.name, state: job.state)
        }
    }

    /// The branch, because that is what a person matches against the
    /// work in front of them. A PR with no head branch — GitHub omits it
    /// on a PR from a deleted fork — falls back to the number.
    public static func branchLabel(_ pr: PullRequest) -> String {
        if let branch = pr.headBranch, !branch.isEmpty { return branch }
        return "\(pr.provider == .gitlab ? "!" : "#")\(pr.number)"
    }

    public func items(in context: MonitorStripContext) -> [MonitorStripItem] {
        activities.map {
            // Already listed, with this very job, in the side panel: a
            // second copy here would only cost a container its slot.
            let redundant = context.prsInSidePanel.contains($0.prID)
            return MonitorStripItem(id: "prjob:\($0.prID)",
                                    priority: redundant ? 0 : Self.priority,
                                    content: .prJob($0))
        }
    }
}

// MARK: - Ranker

public enum MonitorStripRanker {

    /// How many workload pills the strip has room for.
    public static let slots = 3

    /// The edge an item already on screen gets when deciding WHO is shown.
    /// Without it, two candidates hovering around the same priority — a
    /// container at 0.29 and a PR job at 0.3 — trade the last slot on
    /// every poll and the strip flickers. Order among those shown still
    /// follows the raw priority, so a container that heats up visibly
    /// moves past a PR job.
    public static let stickiness = 0.05

    /// The items to show, highest priority first.
    ///
    /// - Parameters:
    ///   - items: every candidate, in the order the sources gave them;
    ///     that order breaks ties.
    ///   - shownBefore: the ids on screen last time.
    public static func select(_ items: [MonitorStripItem], slots: Int = slots,
                              shownBefore: Set<String> = []) -> [MonitorStripItem] {
        let eligible = items.enumerated().filter { $0.element.priority > 0 }

        func ranked(_ list: [(offset: Int, element: MonitorStripItem)],
                    by score: (MonitorStripItem) -> Double) -> [(offset: Int, element: MonitorStripItem)] {
            list.sorted { a, b in
                let (sa, sb) = (score(a.element), score(b.element))
                return sa != sb ? sa > sb : a.offset < b.offset
            }
        }

        let chosen = ranked(eligible) {
            $0.priority + (shownBefore.contains($0.id) ? stickiness : 0)
        }.prefix(max(0, slots))

        return ranked(Array(chosen)) { $0.priority }.map(\.element)
    }

    /// Everything the sources offer, ranked.
    public static func select(from sources: [MonitorStripSource],
                              in context: MonitorStripContext,
                              slots: Int = slots,
                              shownBefore: Set<String> = []) -> [MonitorStripItem] {
        select(sources.flatMap { $0.items(in: context) },
               slots: slots, shownBefore: shownBefore)
    }
}
