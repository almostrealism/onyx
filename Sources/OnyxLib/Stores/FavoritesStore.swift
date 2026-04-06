import Foundation
import SwiftUI
import Combine

// MARK: - Favorite Entry

public struct FavoriteEntry: Codable, Equatable {
    public var sessionID: String
    /// Window indices (0-3) where this favorite is visible. Empty = visible nowhere.
    public var windows: Set<Int>

    public init(sessionID: String, windows: Set<Int> = [0]) {
        self.sessionID = sessionID
        self.windows = windows
    }
}

// MARK: - Shared Favorites Store

/// Singleton that owns the favorites data. All windows read/write through this
/// to avoid race conditions on the shared JSON file.
public class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public var entries: [FavoriteEntry] = []
    private var url: URL?
    private let lock = NSLock()

    private init() {}

    public func configure(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard self.url == nil else { return } // only configure once
        self.url = url
        load()
    }

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        if let entries = try? JSONDecoder().decode([FavoriteEntry].self, from: data) {
            self.entries = entries
        } else if let ids = try? JSONDecoder().decode([String].self, from: data) {
            // Backward compatibility: old format was just [String]
            self.entries = ids.map { FavoriteEntry(sessionID: $0, windows: [0]) }
            save()
        }
    }

    public func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = url else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url)
        }
    }

    /// Reset for testing — clears all entries without saving
    public func reset() {
        lock.lock()
        entries = []
        lock.unlock()
    }
}
