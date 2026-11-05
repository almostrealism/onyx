//
// CompactWindowView.swift
//
// Responsibility: The compact window (⇧⌘D) — simple mode's side panel as
//                 the whole window: sessions and their Claudes, today's
//                 reminders or calendar, open PRs. Small enough to sit
//                 beside whatever else is on screen.
//

import SwiftUI
import OnyxCore

struct CompactWindowView: View {
    @ObservedObject var appState: AppState

    /// Side gutters around the column.
    static let gutter: CGFloat = 16
    /// Clear of the window buttons, which still sit in the top-left
    /// corner — and the strip the window is dragged by.
    static let topInset: CGFloat = 30

    /// The compact window's width the first time: the side panel's own
    /// column, plus its gutters.
    static func width(fontScale: CGFloat) -> CGFloat {
        SimpleSidePanel.columnWidth(fontScale: fontScale) + 2 * gutter
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The monitor's tint, so the compact window reads as the
            // overlay it came from.
            Color.black.opacity(AppearanceConfig.monitorTintOpacity(for: appState.effectiveWindowOpacity))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            SimpleSidePanel(appState: appState, reminders: appState.today.reminders,
                            accentColor: appState.accentColor)
                .padding(.top, Self.topInset)
                .padding(.horizontal, Self.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Button(action: { appState.compactMode = false }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Full window (⇧⌘D)")
            .padding(.top, 4)
            .padding(.trailing, 6)
        }
        .environment(\.monitorFontScale, appState.appearance.uiFontSize / 12.0)
    }
}
