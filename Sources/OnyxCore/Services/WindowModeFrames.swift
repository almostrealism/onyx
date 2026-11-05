//
// WindowModeFrames.swift
//
// Responsibility: The compact window (⇧⌘D) and the full one each keep
//                 their own frame: where each window last had each shape,
//                 the compact shape a window gets the first time, and
//                 keeping a remembered frame on a screen that still exists.
//                 Plus whether a window was compact, so a relaunch comes
//                 back the shape it left.
// Scope: Service. Pure apart from the UserDefaults it is handed.
//
// Per window, by `AppState.windowIndex`, like `PanelSplit` — and on this
// Mac only, for the same reason: a frame that suits one screen is wrong
// on another.
//

import Foundation
import CoreGraphics

public enum WindowModeFrames {

    public enum Mode: String {
        case full, compact
    }

    /// The narrowest and shortest a compact window may be.
    public static let compactMinSize = CGSize(width: 240, height: 240)

    static func frameKey(_ mode: Mode, window: Int) -> String { "windowFrame_\(mode.rawValue)_\(window)" }
    static func compactKey(window: Int) -> String { "windowCompact_\(window)" }

    public static func load(_ mode: Mode, window: Int, from defaults: UserDefaults = .standard) -> CGRect? {
        guard let parts = defaults.array(forKey: frameKey(mode, window: window)) as? [Double],
              parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    public static func save(_ frame: CGRect, as mode: Mode, window: Int, to defaults: UserDefaults = .standard) {
        guard frame.width > 0, frame.height > 0 else { return }
        defaults.set([frame.minX, frame.minY, frame.width, frame.height].map(Double.init),
                     forKey: frameKey(mode, window: window))
    }

    public static func isCompact(window: Int, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactKey(window: window))
    }

    public static func setCompact(_ compact: Bool, window: Int, in defaults: UserDefaults = .standard) {
        defaults.set(compact, forKey: compactKey(window: window))
    }

    /// The compact frame a window gets before it has had one: `width`
    /// wide, as tall as the full window, against its RIGHT edge — the
    /// side panel's content without the rest of the window, left where
    /// the window was, so it doesn't jump across the screen.
    public static func firstCompactFrame(from full: CGRect, width: CGFloat, on screen: CGRect) -> CGRect {
        let w = max(compactMinSize.width, width)
        let frame = CGRect(x: full.maxX - w, y: full.minY, width: w, height: full.height)
        return fitted(frame, on: screen)
    }

    /// `frame` moved (and, only if it must, shrunk) so it lies on
    /// `screen` — a remembered frame may belong to a display that has
    /// since been unplugged or rearranged.
    public static func fitted(_ frame: CGRect, on screen: CGRect) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return frame }
        let w = min(frame.width, screen.width)
        let h = min(frame.height, screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - w)
        let y = min(max(frame.minY, screen.minY), screen.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
