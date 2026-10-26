//
// AlertForwardingStore.swift
//
// Responsibility: Persists how alerts are pushed to the user's phone.
// Scope: Shared singleton.
// Threading: UserDefaults is thread-safe; objectWillChange on writes.
//
// One JSON blob in UserDefaults rather than a key per field — the shape
// changes whenever a service is added, and a struct that round-trips
// through Codable can gain a field without a migration.
//
// Tokens are stored verbatim, following the convention already set by
// GitHubConfigStore and TimingDataStore. Worth knowing rather than
// discovering: a Pushover token in here is as protected as the user's
// login, no more. Nothing in this file is a secret that unlocks anything
// but the ability to send its owner a notification.
//

import Foundation
import Combine

public final class AlertForwardingStore: ObservableObject {
    public static let shared = AlertForwardingStore()

    private static let key = "alert_forwarding"

    private init() {}

    public var config: AlertForwardingConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(AlertForwardingConfig.self, from: data)
            else { return AlertForwardingConfig() }
            return decoded
        }
        set {
            objectWillChange.send()
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Mutate in place — the settings panel binds field by field.
    public func update(_ change: (inout AlertForwardingConfig) -> Void) {
        var next = config
        change(&next)
        config = next
    }

    public func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
