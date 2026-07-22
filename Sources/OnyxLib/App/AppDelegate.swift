import AppKit

/// AppDelegate.
public class AppDelegate: NSObject, NSApplicationDelegate {
    /// Application will finish launching.
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Force the process to be a regular GUI app with menu bar and focus
        NSApplication.shared.setActivationPolicy(.regular)
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
    }
}
