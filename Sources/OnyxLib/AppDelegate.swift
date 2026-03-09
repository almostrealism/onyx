import AppKit

public class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Force the process to be a regular GUI app with menu bar and focus
        NSApplication.shared.setActivationPolicy(.regular)
        ShortcutManager.setupMenuShortcuts()
    }

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

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

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
