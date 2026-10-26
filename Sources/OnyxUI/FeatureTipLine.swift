//
// FeatureTipLine.swift
//
// Responsibility: The one-line "NEW" tip a place shows until it's used or
//                 dismissed. In the shared UI because Today's sections
//                 carry one.
//
import SwiftUI
import OnyxCore

/// "NEW  ⌘V pastes files copied in Finder into this folder  ×" — or
/// nothing, once every tip for `place` is done with.
public struct FeatureTipLine: View {
    let place: FeaturePlace
    let accent: Color
    var fontSize: CGFloat = 10
    /// Space around the tip — applied only when there is one, so a place
    /// with no tip left gives back every point.
    var insets = EdgeInsets()
    @ObservedObject private var tips = FeatureTipStore.shared

    public init(place: FeaturePlace, accent: Color, fontSize: CGFloat = 10,
         insets: EdgeInsets = EdgeInsets()) {
        self.place = place
        self.accent = accent
        self.fontSize = fontSize
        self.insets = insets
    }

    /// Off where the tips don't apply: the Mac's tips name its keys, and
    /// a phone has none (Onyx Today turns them off).
    public static var enabled = true

    public var body: some View {
        if Self.enabled, let feature = tips.tip(at: place) {
            HStack(spacing: 6) {
                Text("NEW")
                    .font(.system(size: fontSize - 2, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(accent.opacity(0.85))
                    .cornerRadius(3)
                Text(feature.tip)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button(action: { tips.dismissTip(feature.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: fontSize - 2, weight: .medium))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Got it — don't show this again")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(accent.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(0.35), lineWidth: 1))
            .cornerRadius(4)
            .help(feature.detail)
            .padding(insets)
            .transition(.opacity)
        }
    }
}
