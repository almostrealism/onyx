import Foundation
import SwiftUI
import Combine

// MARK: - Shared Appearance Store

/// Singleton that owns the appearance config. All windows read/write through
/// this to avoid one window's save overwriting another's changes.
public class AppearanceStore: ObservableObject {
    public static let shared = AppearanceStore()

    @Published public var config = AppearanceConfig()
    private var url: URL?
    private let lock = NSLock()

    private init() {}

    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return }
        self.url = url
        load()
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        if var config = try? JSONDecoder().decode(AppearanceConfig.self, from: data) {
            config.migrateReminders()
            self.config = config
        }
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = url else { return }
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url)
        }
    }

    /// Reset for testing — restores default config without saving
    public func reset() {
        lock.lock()
        config = AppearanceConfig()
        url = nil
        lock.unlock()
    }
}
