import AppKit

public class ShortcutManager {
    /// Per-window AppState registry — keyboard handler queries this to check
    /// overlay state for the specific window that received the event.
    private static var windowAppStates: [Int: () -> AppState?] = [:]  // windowNumber -> weak getter
    private static let lock = NSLock()

    /// Register an AppState for a window. Call from ContentView.onAppear.
    public static func register(window: NSWindow, appState: AppState) {
        let number = window.windowNumber
        lock.lock()
        windowAppStates[number] = { [weak appState] in appState }
        lock.unlock()
    }

    /// Unregister when window closes.
    public static func unregister(window: NSWindow) {
        lock.lock()
        windowAppStates.removeValue(forKey: window.windowNumber)
        lock.unlock()
    }

    /// Get the AppState for the window that owns this event
    private static func appState(for event: NSEvent) -> AppState? {
        guard let window = event.window else { return nil }
        lock.lock()
        let getter = windowAppStates[window.windowNumber]
        lock.unlock()
        return getter?()
    }

    public static func setupMenuShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""

            // Cmd+Shift+E → new note (check shift combo first, before plain Cmd+E)
            if flags.contains([.command, .shift]) && chars.lowercased() == "e" {
                NotificationCenter.default.post(name: .createNote, object: nil)
                return nil
            }

            // Cmd+E → toggle notes
            if flags == .command && chars == "e" {
                NotificationCenter.default.post(name: .toggleNotes, object: nil)
                return nil
            }

            // Cmd+K → command palette
            if flags == .command && chars == "k" {
                NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                return nil
            }

            // Cmd+O → toggle file browser
            if flags == .command && chars == "o" {
                NotificationCenter.default.post(name: .toggleFileBrowser, object: nil)
                return nil
            }

            // Cmd+J → toggle session manager
            if flags == .command && chars == "j" {
                NotificationCenter.default.post(name: .toggleSessionManager, object: nil)
                return nil
            }

            // Shift+Tab → cycle tmux sessions
            if flags == .shift && event.keyCode == 48 {
                NotificationCenter.default.post(name: .cycleTmuxSession, object: nil)
                return nil
            }

            // Cmd+1 through Cmd+9 → switch to favorite by index
            if flags == .command, let n = Int(chars), n >= 1 && n <= 9 {
                NotificationCenter.default.post(name: .switchToFavorite, object: n)
                return nil
            }

            // Cmd+R → refresh/reconnect active session
            if flags == .command && chars == "r" {
                NotificationCenter.default.post(name: .refreshSession, object: nil)
                return nil
            }

            // Cmd+, → settings
            if flags == .command && chars == "," {
                NotificationCenter.default.post(name: .openSettings, object: nil)
                return nil
            }

            // Cmd+D → toggle artifacts panel
            if flags == .command && chars == "d" {
                NotificationCenter.default.post(name: .toggleArtifacts, object: nil)
                return nil
            }

            // Single-key shortcuts — check the state of the EVENT'S window, not a global flag
            let state = appState(for: event)
            let monitorVisibleInWindow = state?.showMonitor ?? false
            let rightPanelInWindow = state?.activeRightPanel != nil

            if !rightPanelInWindow {
                // Backtick/tilde key (keyCode 50) → toggle monitor overlay
                if event.keyCode == 50 && flags.isEmpty {
                    NotificationCenter.default.post(name: .toggleMonitor, object: nil)
                    return nil
                }

                // T key (keyCode 17) → toggle monitor time interval (only when overlay is visible in THIS window)
                if event.keyCode == 17 && flags.isEmpty && monitorVisibleInWindow {
                    NotificationCenter.default.post(name: .toggleMonitorInterval, object: nil)
                    return nil
                }

                // M key (keyCode 46) → toggle memory chart (only when overlay is visible in THIS window)
                if event.keyCode == 46 && flags.isEmpty && monitorVisibleInWindow {
                    NotificationCenter.default.post(name: .toggleMemoryChart, object: nil)
                    return nil
                }

                // C key (keyCode 8) → toggle showing all containers (only when overlay is visible in THIS window)
                if event.keyCode == 8 && flags.isEmpty && monitorVisibleInWindow {
                    NotificationCenter.default.post(name: .toggleAllContainers, object: nil)
                    return nil
                }
            }

            // Escape → dismiss top overlay
            if event.keyCode == 53 && flags.isEmpty {
                NotificationCenter.default.post(name: .escapePressed, object: nil)
            }

            return event
        }
    }
}
