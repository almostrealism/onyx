//
// MonitorFont.swift
//
// Responsibility: The monitor's text scale — every size in the monitor and
//                 the Today sections is a design size at 1.0, multiplied by
//                 the user's UI font scale — shared by the Mac and the
//                 iPhone so a Today section reads the same on both.
//
import SwiftUI

// MARK: - Monitor font scaling
//
// All text in MonitorView and its descendants scales with the user's
// UI font size preference (Settings → UI font size). The "design"
// sizes used at each call site are the values that look right at the
// default scale of 1.0 (when uiFontSize = 12). At other sizes they
// scale proportionally so the visual hierarchy stays intact.

struct MonitorFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

public extension EnvironmentValues {
    /// Scale factor applied to all `.monitorFont(...)` calls inside
    /// MonitorView. Injected at the MonitorView root from
    /// `appearance.uiFontSize / 12`.
    var monitorFontScale: CGFloat {
        get { self[MonitorFontScaleKey.self] }
        set { self[MonitorFontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Use this instead of `.font(.system(size:weight:design:))` for
    /// any text or icon inside MonitorView. The `size` argument is the
    /// design intent at the default UI scale; the ambient
    /// `monitorFontScale` multiplies it. Default design is
    /// `.monospaced` since that's what 95% of MonitorView uses; pass
    /// `.default` explicitly for icons.
    func monitorFont(size: CGFloat,
                     weight: Font.Weight = .regular,
                     design: Font.Design = .monospaced) -> some View {
        modifier(MonitorFontModifier(baseSize: size, weight: weight, design: design))
    }
}

private struct MonitorFontModifier: ViewModifier {
    @Environment(\.monitorFontScale) private var scale
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight, design: design))
    }
}
