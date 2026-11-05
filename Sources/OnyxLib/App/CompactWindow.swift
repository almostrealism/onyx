//
// CompactWindow.swift
//
// Responsibility: Swap a window between its full frame and its compact
//                 one (⇧⌘D), remembering the frame of the shape it leaves
//                 so each comes back the size the user last gave it.
// Scope: Per window; called by ContentView when `AppState.compactMode`
//        changes.
//

import AppKit
import OnyxCore

enum CompactWindow {

    /// Leave `window`'s current shape for the other one.
    ///
    /// The frame being left is saved first. The new frame is set on the
    /// next turn of the run loop: SwiftUI lowers the window's minimum size
    /// (600 wide for the full layout) only once it has re-rendered for
    /// the new mode, and a compact frame set before then is widened back.
    static func apply(compact: Bool, to window: NSWindow, windowIndex: Int, compactWidth: CGFloat) {
        let leaving: WindowModeFrames.Mode = compact ? .full : .compact
        let entering: WindowModeFrames.Mode = compact ? .compact : .full
        let current = window.frame
        WindowModeFrames.save(current, as: leaving, window: windowIndex)
        WindowModeFrames.setCompact(compact, window: windowIndex)

        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let target: CGRect
        if let remembered = WindowModeFrames.load(entering, window: windowIndex) {
            // A remembered frame on a display that's gone is pulled onto
            // the one the window is on now.
            let onAScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(remembered) }
            target = onAScreen ? remembered : WindowModeFrames.fitted(remembered, on: screen)
        } else if compact {
            target = WindowModeFrames.firstCompactFrame(from: current, width: compactWidth, on: screen)
        } else {
            // Never been full in this window (it was launched compact):
            // the app's default size, where the compact window is.
            target = WindowModeFrames.fitted(
                CGRect(x: current.minX, y: current.maxY - 600, width: 900, height: 600), on: screen)
        }
        DispatchQueue.main.async {
            window.setFrame(target, display: true, animate: false)
        }
    }

    /// A window that launched compact: back to its compact frame, if the
    /// system didn't already restore it there.
    static func restore(_ window: NSWindow, windowIndex: Int) {
        guard let remembered = WindowModeFrames.load(.compact, window: windowIndex),
              window.frame != remembered else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let onAScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(remembered) }
        let target = onAScreen ? remembered : WindowModeFrames.fitted(remembered, on: screen)
        DispatchQueue.main.async {
            window.setFrame(target, display: true, animate: false)
        }
    }
}
