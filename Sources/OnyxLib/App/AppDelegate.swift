import AppKit

/// AppDelegate.
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// Application will finish launching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Force the process to be a regular GUI app with menu bar and focus
        NSApplication.shared.setActivationPolicy(.regular)

        // Dark for the whole APPLICATION, not per window.
        //
        // Onyx is a jet-black overlay: every colour in it assumes a dark
        // backdrop. Setting this per window left everything that isn't a
        // window drawing in the SYSTEM appearance — menus, popovers,
        // sheets, the field editor behind every text field — and left
        // any window created after launch unstyled entirely.
        //
        // In Dark Mode that's invisible, because the system appearance
        // already matches; in Light Mode it produces a settings panel of
        // white text fields with our dark chips beside them, which is
        // exactly what users reported and what a dark-mode developer
        // cannot reproduce.
        //
        // Set here rather than in didFinishLaunching so it is in force
        // before the first view is instantiated.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        // Kill macOS "smart" text substitution app-wide BEFORE any text view
        // is created. NSTextView / the window field editor read these defaults
        // for their initial state, so a typed " stays a straight " instead of
        // being auto-curled. Forced (not register:) so it overrides the user's
        // system-wide smart-quotes setting. The TextSanitizer backstop catches
        // anything pasted in.
        for key in ["NSAutomaticQuoteSubstitutionEnabled",
                    "NSAutomaticDashSubstitutionEnabled",
                    "NSAutomaticTextReplacementEnabled"] {
            UserDefaults.standard.set(false, forKey: key)
        }
        ShortcutManager.setupMenuShortcuts()
    }

    /// Application did finish launching.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate and bring to front
        NSApplication.shared.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            // Load the persisted window title
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appearanceURL = appSupport.appendingPathComponent("Onyx").appendingPathComponent("appearance.json")
            var title = "Onyx"
            if let data = try? Data(contentsOf: appearanceURL),
               let config = try? JSONDecoder().decode(AppearanceConfig.self, from: data) {
                title = config.windowTitle
            }

            for window in NSApplication.shared.windows {
                Self.styleWindow(window)
                window.title = title
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Application should terminate after last window closed.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quit path 1: delay termination just long enough to tear the
    /// connection pairs down cleanly (ssh -O exit → PID SIGKILL per
    /// master, bounded per call). Killing the masters closes every mux
    /// channel — terminals included — server-side, so the remote sshd
    /// ends its sessions instead of holding them until keepalive death.
    /// A hard 3s deadline guarantees quit is never hostage to a stuck
    /// ssh; the orphan reaper + willTerminate below are the backstop.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        OnyxLog.ssh.notice("applicationShouldTerminate — tearing down connection pairs")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            ConnectionPairRegistry.shared.shutdown()
            done.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = done.wait(timeout: .now() + 3)
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Quit path 2 (belt-and-braces): shutdown() is idempotent, so this
    /// is a no-op after the normal path — but it still runs when
    /// termination came from somewhere that skipped shouldTerminate.
    public func applicationWillTerminate(_ notification: Notification) {
        OnyxLog.ssh.notice("applicationWillTerminate — final pair shutdown")
        ConnectionPairRegistry.shared.shutdown()
    }

    /// Style window.
    public static func styleWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)

        // Clear the SwiftUI hosting view's background so desktop shows through
        if let hostingView = window.contentView {
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = .clear
        }

        installTitleBarDoubleClick()
    }

    /// Restore double-click-to-zoom in the title-bar strip.
    ///
    /// The window hides its title bar and sets isMovableByWindowBackground,
    /// so SwiftUI content sits where the title bar would be and swallows
    /// the click AppKit would have zoomed on. Dragging still works —
    /// that's handled for background drags — but double-click doesn't,
    /// which is why the window can't be maximised the way every other Mac
    /// window can.
    ///
    /// Deliberately narrow. It only acts on clicks inside the top
    /// `titleBarHeight` points, so a double-click in the terminal still
    /// selects a word, and it honours the system preference — someone who
    /// set double-click to minimise, or to nothing, gets what they asked
    /// for.
    private static let titleBarHeight: CGFloat = 28
    private static var doubleClickMonitor: Any?

    private static func installTitleBarDoubleClick() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.styleMask.contains(.titled) else { return event }

            // Top strip only, in window coordinates (origin bottom-left).
            let y = event.locationInWindow.y
            guard y >= window.frame.height - titleBarHeight else { return event }

            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                // Absent or "Maximize" — zoom, which is the macOS default.
                window.zoom(nil)
            }
            return nil
        }
    }
}
