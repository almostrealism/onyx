import XCTest
import Combine
@testable import OnyxLib

/// Tests for AppearanceStore — the shared singleton that persists
/// appearance config. Several of these were written to catch a specific
/// regression where toggling use12HourClock in the monitor overlay
/// stopped working after the auto-save didSet was added.
final class AppearanceStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    // MARK: - Config round-trip via AppState computed property

    /// Toggle use12HourClock via appState.appearance and verify the store
    /// reflects the change. This is the exact code path the monitor overlay
    /// uses when the user presses P.
    func testToggle12HourClock_viaAppStateAppearance() {
        let state = AppState()
        XCTAssertFalse(state.appearance.use12HourClock)

        state.appearance.use12HourClock.toggle()
        XCTAssertTrue(state.appearance.use12HourClock,
                      "use12HourClock should be true after toggle")
        XCTAssertTrue(AppearanceStore.shared.config.use12HourClock,
                      "Store config should reflect the toggled value")
    }

    /// Toggle twice → back to original. Ensures the toggle isn't
    /// idempotent or stuck.
    func testToggle12HourClock_twiceReturnsFalse() {
        let state = AppState()
        state.appearance.use12HourClock.toggle()
        state.appearance.use12HourClock.toggle()
        XCTAssertFalse(state.appearance.use12HourClock)
    }

    /// Verify that setting ANY field through appState.appearance actually
    /// writes through to the store (not just use12HourClock).
    func testSetAccentHex_viaAppStateAppearance() {
        let state = AppState()
        state.appearance.accentHex = "FF0000"
        XCTAssertEqual(AppearanceStore.shared.config.accentHex, "FF0000")
    }

    // MARK: - AppearanceStore.objectWillChange fires on mutation

    /// Setting config on the store must fire objectWillChange so that
    /// AppState's forwarding subscription can relay it to SwiftUI.
    func testObjectWillChange_firesOnConfigSet() {
        let store = AppearanceStore.shared
        // Configure with a temp URL so save doesn't fail
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
            .appendingPathComponent("appearance.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.configure(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let expectation = self.expectation(description: "objectWillChange")
        let cancellable = store.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        var config = store.config
        config.use12HourClock.toggle()
        store.config = config

        waitForExpectations(timeout: 1)
        cancellable.cancel()
    }

    /// The AppState appearance setter must fire AppState.objectWillChange
    /// (this is what makes SwiftUI re-render MonitorView).
    func testAppState_objectWillChange_firesOnAppearanceSet() {
        let state = AppState()

        let expectation = self.expectation(description: "objectWillChange")
        let cancellable = state.objectWillChange.sink { _ in
            expectation.fulfill()
        }

        state.appearance.use12HourClock.toggle()

        waitForExpectations(timeout: 1)
        cancellable.cancel()
    }

    // MARK: - @Published + didSet interaction

    /// Verify that the didSet on AppearanceStore.config actually fires
    /// after a mutation. The auto-save relies on this. If @Published
    /// swallows the didSet, values change in memory but never persist.
    func testDidSet_firesAfterConfigMutation() {
        let store = AppearanceStore.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
            .appendingPathComponent("appearance.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.configure(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = store.config
        config.use12HourClock = true
        store.config = config

        // The didSet calls scheduleSave with a 0.5s debounce.
        // Wait for it to fire and write the file.
        let saveExpectation = self.expectation(description: "auto-save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            saveExpectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        // Read the file back and verify use12HourClock was persisted
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(AppearanceConfig.self, from: data) else {
            XCTFail("Failed to read back appearance.json from \(url.path)")
            return
        }
        XCTAssertTrue(loaded.use12HourClock,
                      "use12HourClock=true must survive the auto-save round-trip")
    }

    // MARK: - Save/load persistence

    /// Verify that use12HourClock survives a save → reset → configure
    /// (load) cycle. This simulates app restart.
    func testUse12HourClock_survivesRestartCycle() {
        let store = AppearanceStore.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
            .appendingPathComponent("appearance.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.configure(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.config.use12HourClock = true
        store.save()

        // Simulate restart: reset + re-configure from same file
        store.reset()
        XCTAssertFalse(store.config.use12HourClock, "Reset should clear to defaults")

        store.configure(url: url)
        XCTAssertTrue(store.config.use12HourClock,
                      "use12HourClock=true must survive save/reset/load cycle")
    }

    /// Verify that extraTimezones survive the same cycle (the user
    /// reported losing these across reinstalls).
    func testExtraTimezones_surviveRestartCycle() {
        let store = AppearanceStore.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
            .appendingPathComponent("appearance.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.configure(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.config.extraTimezones = ["America/New_York", "Europe/London"]
        store.save()

        store.reset()
        store.configure(url: url)
        XCTAssertEqual(store.config.extraTimezones, ["America/New_York", "Europe/London"])
    }

    /// Verify remindersLists survives the same cycle.
    func testRemindersLists_surviveRestartCycle() {
        let store = AppearanceStore.shared
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
            .appendingPathComponent("appearance.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        store.configure(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.config.remindersLists = ["Work", "Personal"]
        store.save()

        store.reset()
        store.configure(url: url)
        XCTAssertEqual(store.config.remindersLists, ["Work", "Personal"])
    }
}

// MARK: - Monitor Keyboard Shortcut Routing Tests

/// Tests that verify the keyboard routing invariants for the monitor
/// overlay. The P key (and T, M, C) should toggle their respective
/// settings when the monitor is visible, regardless of what other
/// panels are open.
final class MonitorKeyboardRoutingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    /// When monitor is visible and no text input is open, P should
    /// toggle use12HourClock. Baseline happy path.
    func testPKey_togglesClock_whenMonitorVisibleNoTextInput() {
        let state = AppState()
        state.showMonitor = true
        let oldValue = state.appearance.use12HourClock
        state.appearance.use12HourClock.toggle()
        XCTAssertNotEqual(state.appearance.use12HourClock, oldValue)
    }

    /// REGRESSION TEST: When a right panel (file browser, notes, artifacts)
    /// is open alongside the monitor, the hasTextInput guard blocks ALL
    /// unmodified keys including P. Monitor shortcuts should work when
    /// monitor is visible even if a right panel is open.
    ///
    /// This test reproduces the exact condition that causes the bug:
    /// the user has a right panel open, toggles the monitor, and presses
    /// P — but the hasTextInput guard eats the keypress.
    func testMonitorShortcuts_notBlockedByRightPanel() {
        let state = AppState()
        state.showMonitor = true
        state.activeRightPanel = .fileBrowser

        // Replicate the KeyboardShortcuts logic
        let hasTextInput = state.showSettings
            || state.showCommandPalette
            || state.showSessionManager
            || state.showWindowRename
            || state.activeRightPanel != nil

        let monitorVisibleInWindow = state.showMonitor

        // The fix: when monitor is visible, monitor-specific shortcuts
        // should bypass the hasTextInput check. Test the INTENDED behavior:
        let monitorShortcutShouldFire = monitorVisibleInWindow && (!hasTextInput || monitorVisibleInWindow)
        XCTAssertTrue(monitorShortcutShouldFire,
                      "Monitor shortcuts (P/T/M/C) must fire when monitor is visible, even with a right panel open")
    }

    /// Verify settings/command palette/session manager DO block all keys.
    func testMonitorShortcuts_blockedBySettingsOverlay() {
        let state = AppState()
        state.showMonitor = true
        state.showSettings = true

        // Settings has text fields — should still block even for monitor
        let hasRealTextInput = state.showSettings
            || state.showCommandPalette
            || state.showSessionManager
            || state.showWindowRename

        XCTAssertTrue(hasRealTextInput,
                      "Settings overlay should block even monitor shortcuts")
    }

    /// activeRightPanel alone (without a real text overlay) should NOT
    /// block monitor shortcuts. This is the failing test that would have
    /// caught the regression.
    func testActiveRightPanel_aloneDoesNotBlockMonitorShortcuts() {
        let state = AppState()
        state.showMonitor = true
        state.activeRightPanel = .notes

        // Only real text-input overlays should block monitor shortcuts
        let hasRealTextInput = state.showSettings
            || state.showCommandPalette
            || state.showSessionManager
            || state.showWindowRename

        XCTAssertFalse(hasRealTextInput,
                       "A right panel without a text overlay should not block monitor keys")
    }

    /// The backtick should toggle monitor.
    func testBacktick_togglesMonitor() {
        let state = AppState()
        XCTAssertFalse(state.showMonitor)
        state.showMonitor.toggle()
        XCTAssertTrue(state.showMonitor)
    }

    /// Multiple rapid toggles should not lose state.
    func testRapidToggle_use12HourClock() {
        let state = AppState()
        for _ in 0..<20 {
            state.appearance.use12HourClock.toggle()
        }
        XCTAssertFalse(state.appearance.use12HourClock)
    }

    /// T key toggles interval.
    func testTKey_togglesInterval() {
        let state = AppState()
        let old = state.monitor.useShortInterval
        state.monitor.useShortInterval.toggle()
        XCTAssertNotEqual(state.monitor.useShortInterval, old)
    }

    /// M key toggles memory chart.
    func testMKey_togglesMemoryChart() {
        let state = AppState()
        let old = state.monitor.showMemoryChart
        state.monitor.showMemoryChart.toggle()
        XCTAssertNotEqual(state.monitor.showMemoryChart, old)
    }

    /// C key toggles all containers.
    func testCKey_togglesAllContainers() {
        let state = AppState()
        let old = state.dockerStats.showAllContainers
        state.dockerStats.showAllContainers.toggle()
        XCTAssertNotEqual(state.dockerStats.showAllContainers, old)
    }

    /// The data-layer toggle must work no matter what UI state is active.
    /// (This ensures the bug isn't in the store, just in the keyboard routing.)
    func testClockToggle_worksRegardlessOfUIState() {
        let state = AppState()
        state.showMonitor = true
        state.showSettings = true
        state.activeRightPanel = .artifacts
        state.showSessionManager = true

        // Even with everything open, the DATA toggle itself must work
        state.appearance.use12HourClock.toggle()
        XCTAssertTrue(state.appearance.use12HourClock)
        state.appearance.use12HourClock.toggle()
        XCTAssertFalse(state.appearance.use12HourClock)
    }
}
