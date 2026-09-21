//
// PipelineAdderPanel.swift
//
// Responsibility: Adding a pipeline to track — paste a URL, or pick one
//                 from the workflow runs on your open PRs.
// Scope: View. Presented as a card inside the monitor overlay's own
//        ZStack, the same way the note editor and the command palette are.
//
// This used to be a SwiftUI `.popover`, and it CRASHED the app — reliably,
// on the click that opened it. The stack has no Onyx frames in it at all:
//
//   NSPopover _setContentView:size:canAnimate:
//   → NSWindow setFrame:display:animate:
//   → NSMoveHelper _doAnimation          (runs a NESTED runloop)
//   → __CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__
//   → 0x0                                 EXC_BAD_ACCESS
//
// The popover opened small ("Looking up pipelines…"), then grew by up to
// 288pt when the suggestions arrived. That growth is an ANIMATED window
// resize, the animation spins a nested runloop, and in that nested loop a
// runloop observer belonging to a hosting view that has since gone away
// gets called — a jump to a null function pointer.
//
// It is a fragile combination by nature: the anchor is a button inside the
// monitor overlay, which re-renders every time a poller publishes, so the
// view the popover is attached to is being rebuilt underneath it while it
// animates. Making the content a fixed size would dodge this particular
// crash, but the overlay is our own ZStack world — the app already
// presents every other modal as a card in it, none of which have ever
// crashed, and none of which involve AppKit animating a window.
//
// So there is no NSPopover here any more, and nothing resizes.
//

import SwiftUI

struct PipelineAdderPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var ghConfig = GitHubConfigStore.shared
    @ObservedObject private var glConfig = GitLabConfigStore.shared
    @ObservedObject private var prManager = PullRequestManager.shared

    @State private var manualURL: String = ""
    @State private var suggestions: [WorkflowMonitor.Suggestion] = []
    @State private var loading = true

    /// Per-row height: two text lines plus padding and inter-row spacing.
    private static let rowHeight: CGFloat = 36
    /// The list area is a FIXED height whatever it holds — loading,
    /// empty, or full. Nothing in this panel changes size, which is the
    /// whole point of it existing.
    private static let listHeight: CGFloat = rowHeight * 6

    private var existingIDs: Set<String> {
        Set(ghConfig.parsedPipelines.map(\.id) + glConfig.parsedPipelines.map(\.id))
    }

    /// Suggestions minus the ones already tracked, matched on parsed id
    /// rather than URL text — the same pipeline has several spellings.
    private var visibleSuggestions: [WorkflowMonitor.Suggestion] {
        suggestions.filter { s in
            guard let parsed = PipelineSpec.parse(s.url) else { return true }
            return !existingIDs.contains(parsed.id)
        }
    }

    private var canAddManual: Bool {
        PipelineSpec.parse(manualURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 12) {
                Text("ADD PIPELINE")
                    .font(.system(size: 16, weight: .ultraLight, design: .monospaced))
                    .foregroundColor(appState.accentColor)
                    .tracking(6)

                HStack(spacing: 8) {
                    // An NSTextField we focus ourselves, not SwiftUI's. After
                    // one submit the SwiftUI field stopped accepting paste
                    // and couldn't be refocused by clicking — adding a
                    // second pipeline meant reopening the panel. See
                    // FocusedTextField.swift.
                    FocusedSelectAllField(
                        text: $manualURL,
                        placeholder: "Paste a workflow or run URL",
                        font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        textColor: NSColor.white.withAlphaComponent(0.85),
                        onSubmit: { addManual() },
                        onCancel: { close() })
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(4)

                    Button(action: addManual) {
                        Text("Add")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(canAddManual ? .black : .gray)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(canAddManual ? appState.accentColor : Color.white.opacity(0.08))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddManual)
                }

                Divider().background(Color.white.opacity(0.06))

                Text("FROM YOUR OPEN PRs")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
                    .tracking(2)

                listArea
                    .frame(height: Self.listHeight, alignment: .top)

                HStack {
                    Spacer()
                    Button(action: close) {
                        Text("Done")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 20).padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(24)
            .frame(width: 520)
            .background(Color(nsColor: NSColor(white: 0.06, alpha: 0.98)))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .onAppear { loadSuggestions() }
    }

    @ViewBuilder
    private var listArea: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).colorScheme(.dark)
                Text("Looking up pipelines for each open PR…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.5))
            }
        } else if visibleSuggestions.isEmpty {
            Text(suggestions.isEmpty
                 ? "No workflow runs found on any open PR head branch. Paste a URL above instead."
                 : "Everything found on your open PRs is already tracked.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleSuggestions) { s in
                        PipelineSuggestionRow(suggestion: s,
                                              accentColor: appState.accentColor,
                                              onAdd: { add(s.url) })
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func addManual() {
        let trimmed = manualURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PipelineSpec.parse(trimmed) != nil else { return }
        add(trimmed)
        manualURL = ""
    }

    /// Route to the store for the URL's provider — each provider's
    /// pipelines live alongside that provider's token.
    private func add(_ url: String) {
        guard let spec = PipelineSpec.parse(url) else { return }
        switch spec.provider {
        case .github:
            // Skip an equivalent URL that's already tracked: duplicates
            // produce colliding ids downstream.
            guard !ghConfig.pipelineURLs.contains(where: { PipelineSpec.parse($0)?.id == spec.id })
            else { return }
            ghConfig.pipelineURLs.append(url)
            WorkflowMonitor.shared.refresh()
        case .gitlab:
            guard !glConfig.pipelineURLs.contains(where: { PipelineSpec.parse($0)?.id == spec.id })
            else { return }
            glConfig.pipelineURLs.append(url)
            GitLabPipelineMonitor.shared.refresh()
        }
    }

    private func close() {
        appState.showPipelineAdder = false
    }

    private func loadSuggestions() {
        loading = true
        WorkflowMonitor.shared.fetchSuggestions(for: prManager.pullRequests) { results in
            suggestions = results
            loading = false
        }
    }
}

/// One suggested pipeline.
struct PipelineSuggestionRow: View {
    let suggestion: WorkflowMonitor.Suggestion
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The last run's conclusion, so you can see whether a pipeline
            // is currently green before you decide to watch it.
            Circle().fill(conclusionColor)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(suggestion.workflowName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(suggestion.workflowFile)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                        .lineLimit(1)
                }
                Text("\(suggestion.pr.repoFullName)#\(suggestion.pr.number)  ·  \(suggestion.branch)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(accentColor.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Text("Add")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accentColor.opacity(0.12))
                    .cornerRadius(3)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .frame(height: 32)
    }

    private var conclusionColor: Color {
        switch suggestion.mostRecentConclusion {
        case "success": return Color.onyxGreen
        case "failure", "timed_out", "cancelled", "action_required":
            return Color.onyxRed
        case "skipped": return Color.gray.opacity(0.5)
        case nil: return Color.onyxBlue   // in progress
        default: return Color.gray.opacity(0.4)
        }
    }
}
