//
// MonitorStripModels.swift
//
// Responsibility: What can appear in the workload slots along the bottom
//                 of the simple monitor — busy containers, PR jobs in
//                 flight, and whatever comes next — and the facts about
//                 the screen that decide how much each one matters.
// Scope: Pure data. Building items is MonitorStripSources' job; choosing
//        among them is MonitorStripRanker's.
//
// The slots are few and the candidates aren't, so every candidate says
// how much it deserves one: its PRIORITY. The scale is a container's CPU
// in cores — 0.5 is a container using half a core — and everything else
// places itself on that scale. A PR's running job is 0.3: worth more than
// a container idling at 1%, worth less than one doing real work. Zero
// means "don't show me", which is how an item says it is redundant (the
// side panel already lists it) rather than unimportant.
//

import Foundation

/// One candidate for a slot in the bottom strip.
public struct MonitorStripItem: Identifiable, Equatable {
    /// Stable across polls — "container:api", "prjob:github:o/r#12" — so
    /// the ranker can tell an item that is already on screen from a new
    /// one, and SwiftUI doesn't rebuild a pill that only changed numbers.
    public let id: String
    /// How much this item deserves a slot, on the CPU-cores scale above.
    /// Zero or less: never shown.
    public let priority: Double
    public let content: Content

    public init(id: String, priority: Double, content: Content) {
        self.id = id; self.priority = priority; self.content = content
    }

    /// What a pill draws. A new kind of workload is a new case here, a
    /// source that produces it, and a pill that draws it.
    public enum Content: Equatable {
        case container(ContainerLoad)
        case prJob(PRJobActivity)
    }
}

/// One container's current CPU, as the strip shows it.
public struct ContainerLoad: Equatable {
    public let name: String
    /// Docker's own text, "12.34%".
    public let cpuText: String
    /// Percent of one core; 250 is two and a half cores.
    public let cpuPercent: Double
    /// Where the pill's bar is full: every core busy.
    public let maxPercent: Double

    public init(name: String, cpuText: String, cpuPercent: Double, maxPercent: Double) {
        self.name = name; self.cpuText = cpuText
        self.cpuPercent = cpuPercent; self.maxPercent = maxPercent
    }
}

/// The job a PR's CI is busy with right now.
public struct PRJobActivity: Equatable {
    public let prID: String
    /// The branch, or "#12" when there is none — what the side panel
    /// shows for the same PR.
    public let branch: String
    public let prTitle: String
    public let prURL: String
    /// The workflow, "CI".
    public let workflow: String
    /// The job, "unit-tests".
    public let job: String
    public let state: PRPipelineRun.ActiveJob.State

    public init(prID: String, branch: String, prTitle: String, prURL: String,
                workflow: String, job: String, state: PRPipelineRun.ActiveJob.State) {
        self.prID = prID; self.branch = branch; self.prTitle = prTitle; self.prURL = prURL
        self.workflow = workflow; self.job = job; self.state = state
    }
}

/// What else is on screen, for items whose worth depends on it.
///
/// Grows as sources need it: each field is a fact about the screen, not
/// an instruction to any one source, and a source that doesn't care
/// about a field ignores it.
public struct MonitorStripContext: Equatable {
    /// The PRs the side panel is listing right now; empty when it's
    /// closed. A PR there already shows its running job.
    public var prsInSidePanel: Set<String>

    public init(prsInSidePanel: Set<String> = []) {
        self.prsInSidePanel = prsInSidePanel
    }
}
