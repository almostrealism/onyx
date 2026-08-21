import AppKit
import SwiftUI
import OnyxLib

@main
struct OnyxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if let iconURL = Self.appIconURL(), let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    /// Locate AppIcon.icns without touching `Bundle.module`.
    ///
    /// `Bundle.module` is a `static let` that **fatalErrors** when it
    /// can't find its bundle — so merely referencing it crashes the app,
    /// before any window appears. SPM generates it to look in exactly two
    /// places: `Bundle.main.bundleURL/Onyx_Onyx.bundle` (the .app ROOT,
    /// not Contents/Resources, which isn't a legal place to put anything
    /// in a signed bundle) and an ABSOLUTE path into the build directory
    /// of the machine that compiled it.
    ///
    /// So it works on the build machine, from the repo, forever — and
    /// dies instantly on any other Mac, or from a DMG. That is exactly
    /// the crash the first packaged build hit.
    ///
    /// A packaged app has the icon in Contents/Resources, which is where
    /// `Bundle.main` looks, so this never reaches the fallback in a real
    /// bundle. The fallback is only for `swift run` during development,
    /// and it's guarded so a missing bundle returns nil instead of
    /// killing the process.
    private static func appIconURL() -> URL? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return url
        }
        // Development: the SPM resource bundle sits next to the binary.
        let sibling = Bundle.main.bundleURL
            .appendingPathComponent("Onyx_Onyx.bundle")
        if let bundle = Bundle(path: sibling.path) {
            return bundle.url(forResource: "AppIcon", withExtension: "icns")
        }
        return nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
    }
}
