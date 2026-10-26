//
// SecretStore.swift
//
// Responsibility: Every credential Onyx holds — API tokens, and (from the
//                 iOS work on) the Onyx SSH key — kept in the Keychain,
//                 syncing through iCloud Keychain where the app is allowed
//                 to.
// Scope: Shared singleton. One per process.
// Threading: Lock-guarded cache; Keychain calls are thread-safe.
//
// API tokens used to sit in UserDefaults, which is a plist anyone with
// read access to the home folder can open. They also must never travel in
// shared state (CLAUDE.md), and the iPhone and iPad apps need them without
// SSH: iCloud Keychain is the one channel that reaches every device the
// user owns and that Apple encrypts end to end. See docs/ios-plan.md,
// "Shared state and keys".
//
// Where an item goes:
//   1. The data-protection keychain, synchronizable — iCloud Keychain.
//      Needs the app to carry a keychain-access-groups entitlement, which
//      means a provisioning profile. iOS builds always have one.
//   2. Failing that (errSecMissingEntitlement: an ad-hoc signed or
//      Developer ID Mac build without a profile), a 0600 file under the
//      app's support folder, this Mac only — the protection a key in
//      ~/.ssh has, and no less than the UserDefaults plist the tokens
//      came from. Not the login keychain: its access list names the
//      app's code signature, and an ad-hoc build gets a new one with
//      every build, so every rebuild would stop on a password prompt —
//      on a headless Mac, forever. `syncsToOtherDevices` says which
//      happened, so Settings can tell the user the truth.
//
// Reads are cached: the token getters run on every poll, and a Keychain
// lookup costs about a millisecond and can block on a locked keychain.
//

import Foundation
import Security

/// The named secrets. The raw value is the Keychain account.
public enum SecretKey: String, CaseIterable, Sendable {
    case githubToken = "github-token"
    case gitlabToken = "gitlab-token"
    case timingToken = "timing-token"
    case flowtreeClientSecret = "flowtree-client-secret"
    /// The Onyx SSH key: an Ed25519 private key, raw 32 bytes, base64.
    case sshPrivateKey = "ssh-ed25519-key"
    /// Where the home host is and how to check it (JSON, `HomeHostPointer`).
    case homeHost = "home-host"

    /// The UserDefaults key each token lived under before, for the
    /// one-time move. Nil for secrets that never lived there.
    var legacyDefaultsKey: String? {
        switch self {
        case .githubToken: return "github_token"
        case .gitlabToken: return "gitlab_token"
        case .timingToken: return "timing_api_token"
        case .flowtreeClientSecret: return "flowtree_client_secret"
        case .sshPrivateKey, .homeHost: return nil
        }
    }
}

/// Where secrets physically live.
public protocol SecretBackend: AnyObject {
    func read(_ key: SecretKey) -> String?
    /// Throws `SecretStoreError.unavailable` when this backend can't hold
    /// secrets at all in this build (no entitlement), so the store moves on.
    func write(_ key: SecretKey, _ value: String) throws
    func delete(_ key: SecretKey)
}

public enum SecretStoreError: Error, Equatable {
    case unavailable
    case keychain(OSStatus)
    case file(String)
}

public final class SecretStore {

    public static let shared: SecretStore = {
        if isRunningTests {
            // Tests must never write to the keychain or files of whoever
            // runs them.
            return SecretStore(synced: InMemorySecretBackend(), local: InMemorySecretBackend())
        }
        return SecretStore(synced: KeychainSecretBackend(), local: FileSecretBackend.standard())
    }()

    /// iCloud Keychain; refuses when the build lacks the entitlement.
    private let synced: SecretBackend
    /// This device only.
    private let local: SecretBackend?
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [SecretKey: String] = [:]
    private var syncedOnce: Bool?

    public init(synced: SecretBackend, local: SecretBackend?, defaults: UserDefaults = .standard) {
        self.synced = synced
        self.local = local
        self.defaults = defaults
    }

    /// The secret, or "" when there is none — the convention the token
    /// stores already used for "not configured".
    public func get(_ key: SecretKey) -> String {
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()
        let value = synced.read(key) ?? local?.read(key) ?? migrateFromDefaults(key) ?? ""
        lock.lock()
        cache[key] = value
        lock.unlock()
        return value
    }

    /// Store a secret; an empty value deletes it everywhere.
    public func set(_ key: SecretKey, _ value: String) {
        lock.lock()
        cache[key] = value
        lock.unlock()
        if value.isEmpty {
            synced.delete(key)
            local?.delete(key)
            return
        }
        do {
            try store(key, value)
        } catch {
            DiagnosticLog.shared.record("secrets", "couldn't store \(key.rawValue): \(error)")
        }
    }

    /// Synced if this build may, this device otherwise; one copy either way.
    private func store(_ key: SecretKey, _ value: String) throws {
        do {
            try synced.write(key, value)
            local?.delete(key)
            lock.lock(); syncedOnce = true; lock.unlock()
        } catch SecretStoreError.unavailable {
            guard let local else { throw SecretStoreError.unavailable }
            try local.write(key, value)
            lock.lock(); syncedOnce = false; lock.unlock()
        }
    }

    /// Whether secrets reach the user's other devices from this build:
    /// true with iCloud Keychain, false when they stay on this device,
    /// nil until something has been written in this run.
    public var syncsToOtherDevices: Bool? {
        lock.lock(); defer { lock.unlock() }
        return syncedOnce
    }

    /// Whether this secret is held in iCloud Keychain (rather than on this
    /// device only) — answerable at launch, before anything is written.
    public func isSynced(_ key: SecretKey) -> Bool {
        synced.read(key) != nil
    }

    /// Forget cached values, so the next read goes to storage — after
    /// iCloud may have delivered a change from another device.
    public func reload() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// Move a token out of UserDefaults the first time it is read. The old
    /// copy is removed only after the new one is stored: a failed move
    /// must never cost the user their token.
    private func migrateFromDefaults(_ key: SecretKey) -> String? {
        guard let legacy = key.legacyDefaultsKey,
              let value = defaults.string(forKey: legacy), !value.isEmpty else { return nil }
        do {
            try store(key, value)
            defaults.removeObject(forKey: legacy)
        } catch {
            DiagnosticLog.shared.record("secrets", "kept \(legacy) in defaults; couldn't move it: \(error)")
        }
        return value
    }

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

// MARK: - Backends

public final class InMemorySecretBackend: SecretBackend {
    private var items: [SecretKey: String] = [:]
    private let lock = NSLock()
    /// Plays a build without the entitlement.
    public var available: Bool

    public init(available: Bool = true) { self.available = available }

    public func read(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func write(_ key: SecretKey, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard available else { throw SecretStoreError.unavailable }
        items[key] = value
    }

    public func delete(_ key: SecretKey) {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }
}

/// iCloud Keychain: the data-protection keychain, synchronizable.
public final class KeychainSecretBackend: SecretBackend {

    public static let service = "com.almostrealism.onyx"

    public init() {}

    private func query(_ key: SecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: key.rawValue,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func read(_ key: SecretKey) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: SecretKey, _ value: String) throws {
        let data = Data(value.utf8)
        let q = query(key)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess: return
        case errSecMissingEntitlement, errSecNotAvailable:
            throw SecretStoreError.unavailable
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func delete(_ key: SecretKey) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

/// This device only: one 0600 file per secret in a 0700 folder.
public final class FileSecretBackend: SecretBackend {

    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Onyx/secrets` (the app's container on iOS).
    public static func standard() -> FileSecretBackend {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FileSecretBackend(directory: support.appendingPathComponent("Onyx/secrets"))
    }

    private func url(_ key: SecretKey) -> URL { directory.appendingPathComponent(key.rawValue) }

    public func read(_ key: SecretKey) -> String? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: SecretKey, _ value: String) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Created 0600 before the secret is in it, then swapped in whole.
            let temp = directory.appendingPathComponent(".\(key.rawValue).\(UUID().uuidString)")
            guard fm.createFile(atPath: temp.path, contents: Data(value.utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                throw SecretStoreError.file("couldn't create \(temp.lastPathComponent)")
            }
            if fm.fileExists(atPath: url(key).path) {
                _ = try fm.replaceItemAt(url(key), withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url(key))
            }
        } catch let error as SecretStoreError {
            throw error
        } catch {
            throw SecretStoreError.file(error.localizedDescription)
        }
    }

    public func delete(_ key: SecretKey) {
        try? FileManager.default.removeItem(at: url(key))
    }
}
