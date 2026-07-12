//
// FlowtreeConfigStore.swift
//
// Responsibility: Persists the flowtree controller connection settings — the
//                 controller URL and optional Cloudflare Access service-token
//                 credentials (client id + secret). UserDefaults, same
//                 convention as GitHubConfigStore.
// Scope: Shared singleton.
// Threading: UserDefaults is thread-safe; no extra locking.
//

import Foundation
import Combine

public final class FlowtreeConfigStore: ObservableObject {

    public static let shared = FlowtreeConfigStore()

    /// Base URL of the flowtree controller, e.g. `https://flowtree.example.com`
    /// (Cloudflare-fronted) or `http://localhost:7780`. Empty = not configured.
    public var controllerURL: String {
        get { UserDefaults.standard.string(forKey: "flowtree_url") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowtree_url")
            objectWillChange.send()
        }
    }

    /// Cloudflare Access service-token client id. Optional (blank for a local
    /// instance that isn't behind Cloudflare).
    public var clientId: String {
        get { UserDefaults.standard.string(forKey: "flowtree_client_id") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowtree_client_id")
            objectWillChange.send()
        }
    }

    /// Cloudflare Access service-token secret. Optional.
    public var clientSecret: String {
        get { UserDefaults.standard.string(forKey: "flowtree_client_secret") ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowtree_client_secret")
            objectWillChange.send()
        }
    }

    /// True once a controller URL is set — the submit affordance is gated on this.
    public var isConfigured: Bool {
        !controllerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Snapshot as a value type for the stateless client.
    public var config: FlowtreeConfig {
        FlowtreeConfig(baseURL: controllerURL, clientId: clientId, clientSecret: clientSecret)
    }

    private init() {}

    /// Test-only — wipes persisted config so unit tests start clean.
    public func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: "flowtree_url")
        UserDefaults.standard.removeObject(forKey: "flowtree_client_id")
        UserDefaults.standard.removeObject(forKey: "flowtree_client_secret")
        objectWillChange.send()
    }
}
