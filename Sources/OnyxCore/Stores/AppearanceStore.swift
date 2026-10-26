//
// AppearanceStore.swift
//
// Responsibility: Owns the user's AppearanceConfig (font, opacity, accent,
//                 reminders, etc) and persists it to a single JSON file.
// Scope: Shared singleton (AppearanceStore.shared) — used by all windows.
// Threading: An NSLock serializes configure/save/reset; @Published mutations
//            should be made from the main queue.
// Invariants:
//   - configure(url:) is effectively idempotent — only the first call wins
//   - save() is a no-op until configure(url:) has been called
//   - reset() is for tests only; it clears the URL so a re-configure works
//

import Foundation
import SwiftUI
import Combine

// MARK: - Shared Appearance Store

/// Singleton that owns the appearance config. All windows read/write through
/// this to avoid one window's save overwriting another's changes.
///
/// Auto-saves to disk on every change via a Combine subscription on
/// `config`. The deferred-save design (only writing on explicit save()
/// calls) lost data when the app crashed, was force-quit, or when the
/// save call path was never reached.
public class AppearanceStore: ObservableObject {
    /// Shared.
    public static let shared = AppearanceStore()

    @Published public var config = AppearanceConfig() {
        didSet { scheduleSave() }
    }
    private var url: URL?
    private let lock = NSLock()
    private var saveWorkItem: DispatchWorkItem?

    private init() {}

    /// Configure.
    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        load()
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        if var loaded = try? JSONDecoder().decode(AppearanceConfig.self, from: data) {
            loaded.migrateReminders()
            // Set without triggering didSet (which would scheduleSave).
            // We use the lock-guarded _skipDidSet flag for this.
            _skipDidSet = true
            self.config = loaded
            _skipDidSet = false
        }
    }
    private var _skipDidSet = false

    /// Debounced auto-save: coalesces rapid mutations into a single disk
    /// write 0.5s after the last change. Called from config's didSet.
    private func scheduleSave() {
        guard !_skipDidSet else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Write config to disk immediately. Also callable manually.
    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = url else {
            print("AppearanceStore.save: url is nil, skipping")
            return
        }
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            print("AppearanceStore.save failed: \(error)")
        }
    }

    /// Reset for testing — restores default config without saving
    public func reset() {
        lock.lock()
        _skipDidSet = true
        config = AppearanceConfig()
        url = nil
        saveWorkItem?.cancel()
        saveWorkItem = nil
        _skipDidSet = false
        lock.unlock()
    }
}
