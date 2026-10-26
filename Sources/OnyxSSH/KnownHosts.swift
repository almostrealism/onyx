//
// KnownHosts.swift
//
// Responsibility: Deciding whether a server is the one we think it is.
//                 The same accept-new rule Onyx gives OpenSSH
//                 (`StrictHostKeyChecking=accept-new`): a host seen for the
//                 first time is trusted and remembered; a host whose key
//                 CHANGED is refused, loudly.
// Scope: One store per app, a JSON file beside the app's other state.
// Threading: Lock-guarded; verification runs on an event loop.
//
// A key can also be pinned before the first connection — the home host's
// key arrives through iCloud Keychain with its address — so the very first
// connection from a new iPhone is checked rather than trusted.
//
// On a Mac, the user's ~/.ssh/known_hosts is consulted too, read-only: a
// host OpenSSH already knows shouldn't be "new" to the built-in client,
// and a key OpenSSH would refuse must be refused here as well.
//

import Foundation
import Crypto
import NIOCore
import NIOSSH

public final class KnownHostsStore {

    public enum Verdict: Equatable {
        case trusted
        /// First sight; remembered.
        case new
        /// The key differs from the one on record: refuse.
        case changed(expected: String)
    }

    private let url: URL?
    private let openSSHFiles: [URL]
    private let lock = NSLock()
    /// "[host]:port" (or "host" for 22) → "ssh-ed25519 AAAA…"
    private var keys: [String: String] = [:]

    /// The app's store: `known_hosts.json` in Application Support, plus
    /// `~/.ssh/known_hosts` on a Mac.
    public static let shared: KnownHostsStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #if os(macOS)
        let openSSH = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")]
        #else
        let openSSH: [URL] = []
        #endif
        return KnownHostsStore(url: support?.appendingPathComponent("Onyx/known_hosts.json"),
                               openSSHFiles: openSSH)
    }()

    /// `url` nil keeps everything in memory (tests).
    public init(url: URL?, openSSHFiles: [URL] = []) {
        self.url = url
        self.openSSHFiles = openSSHFiles
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            keys = saved
        }
    }

    /// The name OpenSSH files a host under.
    public static func entryName(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Record a key before ever connecting (the home host's, from iCloud).
    public func pin(host: String, port: Int, key: String) {
        lock.lock()
        keys[Self.entryName(host: host, port: port)] = Self.normalize(key)
        lock.unlock()
        save()
    }

    public func forget(host: String, port: Int) {
        lock.lock()
        keys[Self.entryName(host: host, port: port)] = nil
        lock.unlock()
        save()
    }

    public func key(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[Self.entryName(host: host, port: port)]
    }

    /// Check `presented` for `host:port`, remembering it if it's new.
    public func verify(host: String, port: Int, presented: NIOSSHPublicKey) -> Verdict {
        let name = Self.entryName(host: host, port: port)
        let line = String(openSSHPublicKey: presented)
        lock.lock()
        let mine = keys[name]
        lock.unlock()
        if let mine {
            return mine == line ? .trusted : .changed(expected: mine)
        }
        let theirs = openSSHKeys(for: host, port: port)
        if !theirs.isEmpty {
            // OpenSSH may hold several key types for a host; any match is
            // the host, and a host it knows with none of them matching is
            // the warning OpenSSH would print.
            let presentedType = line.split(separator: " ").first.map(String.init) ?? ""
            if theirs.contains(line) { return .trusted }
            if let sameType = theirs.first(where: { $0.hasPrefix(presentedType + " ") }) {
                return .changed(expected: sameType)
            }
        }
        lock.lock()
        keys[name] = line
        lock.unlock()
        save()
        return .new
    }

    private func save() {
        guard let url else { return }
        lock.lock()
        let snapshot = keys
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func normalize(_ key: String) -> String {
        key.split(separator: " ").prefix(2).joined(separator: " ")
    }

    // MARK: - OpenSSH known_hosts (read-only)

    /// Every key OpenSSH's files hold for this host, plain or hashed
    /// (`|1|salt|hash`, HMAC-SHA1 of the entry name).
    func openSSHKeys(for host: String, port: Int) -> [String] {
        let name = Self.entryName(host: host, port: port)
        var found: [String] = []
        for file in openSSHFiles {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@") else { continue }
                let fields = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
                guard fields.count >= 3 else { continue }
                let hosts = fields[0]
                let matches: Bool
                if hosts.hasPrefix("|1|") {
                    matches = Self.hashedEntry(hosts, matches: name)
                } else {
                    matches = hosts.split(separator: ",").contains { $0 == name }
                }
                if matches { found.append(Self.normalize(fields[1] + " " + fields[2])) }
            }
        }
        return found
    }

    static func hashedEntry(_ entry: String, matches name: String) -> Bool {
        let parts = entry.split(separator: "|", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "1",
              let salt = Data(base64Encoded: String(parts[1])),
              let hash = Data(base64Encoded: String(parts[2])) else { return false }
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
        return Data(mac) == hash
    }
}

/// NIOSSH's server-authentication delegate, backed by the store.
final class KnownHostsVerifier: NIOSSHClientServerAuthenticationDelegate {
    private let store: KnownHostsStore
    private let host: String
    private let port: Int
    /// What happened, for the error message when the connection fails.
    private(set) var verdict: KnownHostsStore.Verdict?

    init(store: KnownHostsStore, host: String, port: Int) {
        self.store = store
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let verdict = store.verify(host: host, port: port, presented: hostKey)
        self.verdict = verdict
        switch verdict {
        case .trusted, .new:
            validationCompletePromise.succeed(())
        case .changed:
            validationCompletePromise.fail(SSHConnectionError.hostKeyChanged(
                host: KnownHostsStore.entryName(host: host, port: port),
                presented: String(openSSHPublicKey: hostKey)))
        }
    }
}
