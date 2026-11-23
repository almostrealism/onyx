//
// PRDetailsCard.swift
//
// Responsibility: A PR's full details on hover — what a one-line row had
//                 to leave out: the whole title, where it stands, every
//                 label and every workflow's latest run.
// Scope: Shared SwiftUI (OnyxUI). A row says which PR it shows with
//        `.prDetailsOnHover(pr, runs:)`; a container that wants the
//        cards says so with `.prDetailsHost()`, and draws them in its own
//        layer. Without a host the modifier does nothing — the iPhone and
//        the widget show the same rows with no card.
//
// Not a `.popover`: an NSPopover whose content changes size crashes the
// app (CLAUDE.md), and a card full of live CI does change size. It is a
// view in the host's own ZStack, positioned by `PRDetails.placement`,
// and it never takes the pointer, so it can't flicker its own row's
// hover off and on.
//

import SwiftUI
import OnyxCore

// MARK: - The card

public struct PRDetailsCard: View {
    let pr: PullRequest
    let runs: [PRPipelineRun]
    let accentColor: Color
    var width: CGFloat

    public static let width: CGFloat = 340

    public init(pr: PullRequest, runs: [PRPipelineRun], accentColor: Color,
                width: CGFloat = PRDetailsCard.width) {
        self.pr = pr
        self.runs = runs
        self.accentColor = accentColor
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(pr.title)
                .monitorFont(size: 13, weight: .medium)
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            state
            if !pr.labels.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 3) {
                    ForEach(pr.labels, id: \.name) { PRLabelChip(label: $0) }
                }
            }
            if !runs.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runs) { run in runBlock(run) }
                }
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.07).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentColor.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 14, y: 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(pr.provider.badge)
                .monitorFont(size: 8, weight: .bold)
                .foregroundColor(Color(hex: pr.provider.badgeHex))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color(hex: pr.provider.badgeHex).opacity(0.14))
                .cornerRadius(2)
            Text(PRDetails.reference(pr))
                .monitorFont(size: 10)
                .foregroundColor(accentColor.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if pr.isDraft {
                Text("DRAFT")
                    .monitorFont(size: 8, weight: .bold)
                    .foregroundColor(.gray.opacity(0.7))
                    .tracking(1)
            }
        }
    }

    private var state: some View {
        let merge = PRDetails.merge(pr.mergeStatus)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(merge.tone)).frame(width: 6, height: 6)
                Text(merge.text)
                    .monitorFont(size: 11)
                    .foregroundColor(color(merge.tone).opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let threads = PRDetails.threads(pr.openCommentThreads) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9))
                    Text(threads)
                        .monitorFont(size: 11)
                }
                .foregroundColor(Color.onyxAmber.opacity(0.8))
            }
            HStack(spacing: 6) {
                if let branch = pr.headBranch {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.5))
                    Text(branch)
                        .monitorFont(size: 10)
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let author = pr.author {
                    Text("by \(author)")
                        .monitorFont(size: 10)
                        .foregroundColor(.gray.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
    }

    private func runBlock(_ run: PRPipelineRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                PipelineStatusDot(overall: run.overall)
                Text(run.name)
                    .monitorFont(size: 11, weight: .medium)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                Text(PRDetails.runMeta(run))
                    .monitorFont(size: 10)
                    .foregroundColor(.gray.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if let job = run.activeJob {
                Text(PRDetails.activeJob(job))
                    .monitorFont(size: 10)
                    .foregroundColor(job.state == .running ? Color.onyxBlue.opacity(0.9)
                                                           : Color.onyxAmber.opacity(0.85))
                    .padding(.leading, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !run.failedJobs.isEmpty {
                // Every one: this is the place with room for them.
                Text("failed: " + run.failedJobs.joined(separator: ", "))
                    .monitorFont(size: 10)
                    .foregroundColor(Color.onyxRed.opacity(0.85))
                    .padding(.leading, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ tone: PRDetails.Tone) -> Color {
        switch tone {
        case .good: return Color.onyxGreen
        case .caution: return Color.onyxAmber
        case .bad: return Color.onyxRed
        case .quiet: return .gray
        }
    }
}

// MARK: - Hover

/// Which PR is under the pointer, and where its row is. One per host.
///
/// Shows after a short rest, so sweeping the pointer across a list
/// doesn't strobe cards; once one is up, moving to another row swaps it
/// at once, like the system's tooltips. Leaving hides it after a beat, so
/// crossing the gap between two rows doesn't blink.
@MainActor
public final class PRHoverCenter: ObservableObject {
    public struct Item: Equatable {
        public let pr: PullRequest
        public let runs: [PRPipelineRun]
        public let anchor: CGRect
    }

    @Published public private(set) var shown: Item?

    public static let showDelay: TimeInterval = 0.45
    public static let hideDelay: TimeInterval = 0.12

    private var pending: DispatchWorkItem?
    private var hovering: String?

    public init() {}

    public func enter(_ pr: PullRequest, runs: [PRPipelineRun], anchor: CGRect) {
        hovering = pr.id
        pending?.cancel()
        let item = Item(pr: pr, runs: runs, anchor: anchor)
        if shown != nil {
            shown = item
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering == pr.id else { return }
            self.shown = item
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    /// The row moved (a scroll, a resize, new data) — follow it.
    public func update(_ pr: PullRequest, runs: [PRPipelineRun], anchor: CGRect) {
        guard hovering == pr.id, let current = shown, current.pr.id == pr.id else { return }
        let item = Item(pr: pr, runs: runs, anchor: anchor)
        if item != current { shown = item }
    }

    public func leave(_ pr: PullRequest) {
        guard hovering == pr.id else { return }
        hovering = nil
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering == nil else { return }
            self.shown = nil
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }

    /// Hide now — the host is going away, or the user clicked.
    public func dismiss() {
        pending?.cancel()
        hovering = nil
        shown = nil
    }
}

private struct PRHoverCenterKey: EnvironmentKey {
    static let defaultValue: PRHoverCenter? = nil
}

extension EnvironmentValues {
    /// The host's hover center; nil where nothing hosts cards.
    public var prHoverCenter: PRHoverCenter? {
        get { self[PRHoverCenterKey.self] }
        set { self[PRHoverCenterKey.self] = newValue }
    }
}

enum PRDetailsSpace {
    static let name = "onyx.prDetails"
}

/// Marks a row as showing `pr`, so hovering it shows its card.
private struct PRDetailsOnHover: ViewModifier {
    @Environment(\.prHoverCenter) private var center
    let pr: PullRequest
    let runs: [PRPipelineRun]
    @State private var frame: CGRect = .zero
    @State private var inside = false

    func body(content: Content) -> some View {
        if let center {
            content
                .background(GeometryReader { geo in
                    Color.clear.onChange(of: geo.frame(in: .named(PRDetailsSpace.name)), initial: true) { _, new in
                        frame = new
                        if inside { center.update(pr, runs: runs, anchor: new) }
                    }
                })
                .onHover { now in
                    inside = now
                    if now { center.enter(pr, runs: runs, anchor: frame) } else { center.leave(pr) }
                }
                .onChange(of: runs) { _, new in
                    if inside { center.update(pr, runs: new, anchor: frame) }
                }
                .onDisappear { if inside { center.leave(pr) } }
        } else {
            content
        }
    }
}

/// Draws the hovered PR's card over this view, beside its row.
private struct PRDetailsHost: ViewModifier {
    @StateObject private var center = PRHoverCenter()
    let accentColor: Color
    @State private var cardSize: CGSize = CGSize(width: PRDetailsCard.width, height: 160)

    func body(content: Content) -> some View {
        content
            .environment(\.prHoverCenter, center)
            .coordinateSpace(name: PRDetailsSpace.name)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    if let item = center.shown {
                        let origin = PRDetails.placement(anchor: item.anchor, card: cardSize,
                                                         in: geo.size)
                        // Narrower than the card (the compact window):
                        // the card narrows instead of hanging off the edge.
                        PRDetailsCard(pr: item.pr, runs: item.runs, accentColor: accentColor,
                                      width: min(PRDetailsCard.width, max(200, geo.size.width - 16)))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { card in
                                Color.clear.onChange(of: card.size, initial: true) { _, new in
                                    cardSize = new
                                }
                            })
                            .offset(x: origin.x, y: origin.y)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.12), value: center.shown?.pr.id)
    }
}

extension View {
    /// Hovering this row shows `pr`'s details card, where a host is.
    public func prDetailsOnHover(_ pr: PullRequest, runs: [PRPipelineRun]) -> some View {
        modifier(PRDetailsOnHover(pr: pr, runs: runs))
    }

    /// Show PR details cards for rows inside this view, drawn over it.
    public func prDetailsHost(accentColor: Color) -> some View {
        modifier(PRDetailsHost(accentColor: accentColor))
    }
}
