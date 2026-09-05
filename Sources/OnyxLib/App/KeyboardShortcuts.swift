import AppKit
import SwiftTerm

/// ShortcutManager.
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

    /// Setup menu shortcuts.
    public static func setupMenuShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""

            // Cmd+Shift+C → toggle terminal text mode (selectable text view)
            if flags.contains([.command, .shift]) && chars.lowercased() == "c" {
                NotificationCenter.default.post(name: .toggleTerminalTextMode, object: nil)
                return nil
            }

            // Cmd+Shift+E → new note (check shift combo first, before plain Cmd+E)
            if flags.contains([.command, .shift]) && chars.lowercased() == "e" {
                NotificationCenter.default.post(name: .createNote, object: nil)
                return nil
            }

            // Cmd+Shift+F → jump to file search (focused on the last favorite,
            // or search the current selection if there is one)
            if flags.contains([.command, .shift]) && chars.lowercased() == "f" {
                NotificationCenter.default.post(name: .searchFiles, object: nil)
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

            // Cmd+/ → help / keyboard-shortcut reference
            if flags == .command && chars == "/" {
                NotificationCenter.default.post(name: .toggleHelp, object: nil)
                return nil
            }

            // Cmd+O → toggle file browser (right panel)
            // Cmd+Shift+O → toggle full-window file browser
            if chars.lowercased() == "o" {
                if flags == .command {
                    NotificationCenter.default.post(name: .toggleFileBrowser, object: nil)
                    return nil
                }
                if flags.contains([.command, .shift]) {
                    NotificationCenter.default.post(name: .toggleFullFileBrowser, object: nil)
                    return nil
                }
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

            // Cmd+\ → cycle panel split ratio
            if flags == .command && event.keyCode == 42 {
                NotificationCenter.default.post(name: .cyclePanelSize, object: nil)
                return nil
            }

            // Cmd+, → settings
            if flags == .command && chars == "," {
                NotificationCenter.default.post(name: .openSettings, object: nil)
                return nil
            }

            // Cmd+; → set / edit status note on active session
            if flags == .command && chars == ";" {
                NotificationCenter.default.post(name: .editSessionNote, object: nil)
                return nil
            }

            // Cmd+Ctrl+Arrow → resize tmux pane by 4 cells
            if flags.contains([.command, .control]) {
                switch event.keyCode {
                case 126: // Up arrow
                    NotificationCenter.default.post(name: .tmuxResizeUp, object: nil)
                    return nil
                case 125: // Down arrow
                    NotificationCenter.default.post(name: .tmuxResizeDown, object: nil)
                    return nil
                case 123: // Left arrow
                    NotificationCenter.default.post(name: .tmuxResizeLeft, object: nil)
                    return nil
                case 124: // Right arrow
                    NotificationCenter.default.post(name: .tmuxResizeRight, object: nil)
                    return nil
                default:
                    break
                }
            }

            // Cmd+L → focus URL bar (the URLBar ignores it if not visible)
            if flags == .command && chars == "l" {
                NotificationCenter.default.post(name: .focusURLBar, object: nil)
                return nil
            }

            // Cmd+D → toggle artifacts panel
            if flags == .command && chars == "d" {
                NotificationCenter.default.post(name: .toggleArtifacts, object: nil)
                return nil
            }

            // Cmd+Option+Left / Right → move focus between the terminal and
            // the open right panel.
            //
            // Directional rather than a toggle: with a toggle you have to
            // know where focus currently is to predict where it lands, and
            // not knowing that is the actual complaint. Left is always the
            // terminal, right is always the panel, whatever you pressed
            // last. Cmd+Ctrl+arrows are tmux pane resize; these are free.
            if flags == [.command, .option] {
                if event.keyCode == 123 {   // Left
                    NotificationCenter.default.post(name: .focusTerminal, object: nil)
                    return nil
                }
                if event.keyCode == 124 {   // Right
                    NotificationCenter.default.post(name: .focusRightPanel, object: nil)
                    return nil
                }
            }

            // Single-key shortcuts — check the state of the EVENT'S window.
            let state = appState(for: event)

            // Who is actually going to receive this keystroke?
            //
            // This is the authority, not `focusedComponent`. AppKit
            // delivers typed characters to the first responder; our flag
            // is a separate model that can and did drift out of step with
            // it. When they disagreed the result was the worst possible
            // outcome: most characters reached the shell while space was
            // taken by the file browser, so the terminal was neither
            // usable nor properly locked out.
            //
            // Anything that claims a BARE key now asks this question, so
            // "does my typing go to the terminal" and "does space go to
            // the terminal" can only ever have the same answer.
            let terminalHasKeyboard = event.window?.firstResponder is TerminalView

            // A field editor holds the keyboard whenever the user is
            // typing into any text field — including the file browser's
            // own search box. Space belongs to whatever is being typed
            // into, always; searching for "release notes" must not fire a
            // preview halfway through.
            let textFieldHasKeyboard = event.window?.firstResponder is NSTextView

            // Keep the model honest. The focus outline reads from
            // `focusedComponent`, so without this it goes on describing a
            // state the keyboard isn't in. Assigning only on a real
            // disagreement means this settles on the first keystroke
            // instead of churning SwiftUI on every one.
            if let state, terminalHasKeyboard, state.focusedComponent == .rightPanel {
                DispatchQueue.main.async { state.focusedComponent = .terminal }
            }
            let monitorVisibleInWindow = state?.showMonitor ?? false

            // "Real" text-input overlays that should block ALL unmodified keys:
            // settings, command palette, session manager, window rename.
            // Right panels (notes, file browser, artifacts) do NOT block
            // monitor-specific shortcuts (P/T/M/C) because the monitor
            // overlay is visually on top of the panel and the user expects
            // those keys to work.
            let hasRealTextInput = (state?.showSettings ?? false)
                || (state?.showCommandPalette ?? false)
                || (state?.showSessionManager ?? false)
                || (state?.showWindowRename ?? false)
                || (state?.showSessionNoteEditor ?? false)
                || (state?.showHelp ?? false)

            // For non-monitor shortcuts, also suppress when a right panel
            // with an editor is open (notes, file browser text fields).
            let hasAnyTextInput = hasRealTextInput
                || (state?.activeRightPanel != nil)

            // Monitor-specific shortcuts: fire when monitor is visible,
            // no real text overlay is active, AND the focus ring is on the
            // terminal (not on a right panel like file browser or notes).
            // When a right panel has focus, the user expects to type into
            // it — the orange focus ring makes this visually clear.
            let rightPanelHasFocus = (state?.focusedComponent == .rightPanel)
            if monitorVisibleInWindow && !hasRealTextInput && !rightPanelHasFocus && flags.isEmpty {
                switch event.keyCode {
                case 17: // T → toggle interval
                    NotificationCenter.default.post(name: .toggleMonitorInterval, object: nil)
                    return nil
                case 46: // M → toggle memory chart
                    NotificationCenter.default.post(name: .toggleMemoryChart, object: nil)
                    return nil
                case 8:  // C → toggle all containers
                    NotificationCenter.default.post(name: .toggleAllContainers, object: nil)
                    return nil
                case 35: // P → toggle 12/24hr clock
                    NotificationCenter.default.post(name: .toggleClockFormat, object: nil)
                    return nil
                case 1: // S → detailed / simple density
                    NotificationCenter.default.post(name: .toggleSimpleMonitor, object: nil)
                    return nil
                case 3: // F → cycle fleet mode (this host → top N → fleet max)
                    NotificationCenter.default.post(name: .cycleFleetMode, object: nil)
                    return nil
                case 7: // X → peek behind the overlay (drop to 30% opacity)
                    NotificationCenter.default.post(name: .toggleMonitorPeek, object: nil)
                    return nil
                case 2: // D → simple mode: sessions + today's reminders down the left
                    NotificationCenter.default.post(name: .toggleSimpleSidePanel, object: nil)
                    return nil
                case 15: // R → reminders: only what's due today/tomorrow
                    NotificationCenter.default.post(name: .toggleRemindersDueSoon, object: nil)
                    return nil
                default:
                    break
                }
            }

            // Cmd+Y → toggle the file preview from anywhere, focus or not.
            //
            // The counterpart to space being focus-gated: a Cmd chord is
            // reserved by macOS and never reaches the shell, so this is
            // safe to leave global in a way a bare key never is. Cmd+Y is
            // also Finder's own second Quick Look shortcut, which is the
            // gesture this is imitating.
            if flags == .command && chars.lowercased() == "y" {
                let browserOpen = (state?.showFullFileBrowser ?? false)
                    || (state?.activeRightPanel == .fileBrowser)
                if browserOpen && state?.fileBrowserManager.viewingFileName != nil {
                    NotificationCenter.default.post(name: .toggleFilePreview, object: nil)
                    return nil
                }
            }

            // Space bar in file browser → toggle file preview overlay.
            //
            // Gated on the file browser actually HAVING focus. It used to
            // fire whenever the panel was open and a file was selected,
            // which meant every space typed into the terminal toggled a
            // preview and never reached the shell — the panel and the
            // terminal both acting on one keystroke. A bare key may only
            // be claimed by the component the user is pointed at; that is
            // the rule for anything added here.
            let fileBrowserActive = (state?.showFullFileBrowser ?? false)
                || (state?.activeRightPanel == .fileBrowser)
            if event.keyCode == 49 && flags.isEmpty && fileBrowserActive
                && !terminalHasKeyboard && !textFieldHasKeyboard
                && state?.fileBrowserManager.viewingFileName != nil
                && !hasRealTextInput {
                NotificationCenter.default.post(name: .toggleFilePreview, object: nil)
                return nil
            }

            // Other single-key shortcuts: suppress when any text input is active
            if !hasAnyTextInput {
                // Backtick/tilde key (keyCode 50) → toggle monitor overlay
                if event.keyCode == 50 && flags.isEmpty {
                    NotificationCenter.default.post(name: .toggleMonitor, object: nil)
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
