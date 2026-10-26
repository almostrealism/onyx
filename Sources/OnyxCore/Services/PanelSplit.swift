//
// PanelSplit.swift
//
// Responsibility: The side panel's share of the window: its limits, the
//                 widths ⌘\ steps through, and where each window keeps
//                 its own across launches.
// Scope: Service. Pure apart from the UserDefaults it is handed.
//
// Per window, by `AppState.windowIndex`: the pool hands out the lowest free
// index, so the first window after a relaunch is window 0 again and gets
// window 0's width back. Kept on this Mac only — a width that suits one
// screen is wrong on another, so it doesn't belong in synced appearance.
//

import Foundation

public enum PanelSplit {

    public static let defaultFraction: Double = 0.4
    public static let minFraction: Double = 0.2
    public static let maxFraction: Double = 0.85
    /// What ⌘\ steps through.
    public static let presets: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7]

    public static func clamped(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultFraction }
        return min(max(fraction, minFraction), maxFraction)
    }

    /// The next preset wider than `current`, wrapping to the narrowest.
    public static func nextPreset(after current: Double) -> Double {
        presets.first(where: { $0 > current + 0.01 }) ?? presets[0]
    }

    /// The panel's share of the window when the divider sits at `x` in a
    /// window `width` wide.
    public static func fraction(dividerAt x: Double, width: Double) -> Double {
        guard width > 0 else { return defaultFraction }
        return clamped((width - x) / width)
    }

    static func key(window: Int) -> String { "rightPanelFraction_\(window)" }

    public static func load(window: Int, from defaults: UserDefaults = .standard) -> Double {
        guard let stored = defaults.object(forKey: key(window: window)) as? Double else {
            return defaultFraction
        }
        return clamped(stored)
    }

    public static func save(_ fraction: Double, window: Int, to defaults: UserDefaults = .standard) {
        defaults.set(clamped(fraction), forKey: key(window: window))
    }
}
