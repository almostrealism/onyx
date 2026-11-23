//
// PRDetails.swift
//
// Responsibility: The words a PR's details card uses — its reference, its
//                 merge state, each run's one-line summary — and where the
//                 card goes beside the row it describes.
// Scope: Service. Pure functions, so the card's wording and placement
//        are tested without drawing anything.
//

import Foundation
import CoreGraphics

public enum PRDetails {

    /// "owner/repo#412", or "group/project!57" for a GitLab MR.
    public static func reference(_ pr: PullRequest) -> String {
        "\(pr.repoFullName)\(pr.provider == .gitlab ? "!" : "#")\(pr.number)"
    }

    /// How a merge state reads, and how worried to be about it.
    public enum Tone: Equatable { case good, caution, bad, quiet }

    public static func merge(_ status: PRMergeStatus) -> (text: String, tone: Tone) {
        switch status {
        case .ready: return ("ready to merge", .good)
        case .behind: return ("behind its base branch", .caution)
        case .blocked: return ("blocked by reviews or branch rules", .caution)
        case .conflicts: return ("has merge conflicts", .bad)
        case .checksFailing: return ("checks failing", .bad)
        case .unknown: return ("merge state not known yet", .quiet)
        }
    }

    /// "1 unresolved thread" / "3 unresolved threads", nil for none.
    public static func threads(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 unresolved thread" : "\(count) unresolved threads"
    }

    /// `#412 · attempt 2 · 3m ago` — the attempt only on a re-run.
    public static func runMeta(_ run: PRPipelineRun, now: Date = Date()) -> String {
        var parts: [String] = []
        if let n = run.runNumber { parts.append("#\(n)") }
        if run.isRetry, let attempt = run.attempt { parts.append("attempt \(attempt)") }
        if let at = run.updatedAt { parts.append(ago(at, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// "running test (macos) for 4m" / "queued build-arm64 for 1m".
    public static func activeJob(_ job: PRPipelineRun.ActiveJob, now: Date = Date()) -> String {
        let verb = job.state == .running ? "running" : "queued"
        guard let since = job.since else { return "\(verb) \(job.name)" }
        return "\(verb) \(job.name) for \(duration(now.timeIntervalSince(since)))"
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 90 { return "just now" }
        return "\(duration(TimeInterval(s))) ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 90 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    // MARK: - Placement

    /// Where the card's top-left goes, in the space both share.
    ///
    /// Beside the row — right if it fits, else left — so the row and its
    /// neighbors stay visible; top-aligned with the row, but pulled up so
    /// the whole card is on screen. A container too narrow for either side
    /// gets the card under the row instead, clamped the same way.
    public static func placement(anchor: CGRect, card: CGSize, in container: CGSize,
                                 gap: CGFloat = 10, margin: CGFloat = 8) -> CGPoint {
        func clampY(_ y: CGFloat) -> CGFloat {
            max(margin, min(y, container.height - card.height - margin))
        }
        func clampX(_ x: CGFloat) -> CGFloat {
            max(margin, min(x, container.width - card.width - margin))
        }
        let right = anchor.maxX + gap
        if right + card.width <= container.width - margin {
            return CGPoint(x: right, y: clampY(anchor.minY))
        }
        let left = anchor.minX - gap - card.width
        if left >= margin {
            return CGPoint(x: left, y: clampY(anchor.minY))
        }
        // Neither side: below the row if there's room, above if not.
        let below = anchor.maxY + gap
        let y = below + card.height <= container.height - margin
            ? below : anchor.minY - gap - card.height
        return CGPoint(x: clampX(anchor.minX), y: clampY(y))
    }
}
