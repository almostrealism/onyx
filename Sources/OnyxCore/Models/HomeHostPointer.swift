//
// HomeHostPointer.swift
//
// Responsibility: What a new iPhone or iPad needs to find the home host
//                 and trust it on the first connection — its address, the
//                 account, and its host key — and the pairing code that
//                 carries it (with the Onyx key) when iCloud Keychain can't.
// Scope: Model. Stored as JSON in SecretStore (`.homeHost`), which syncs
//        it through iCloud Keychain beside the key (docs/ios-plan.md,
//        "How a new device is set up").
//

import Foundation

public struct HomeHostPointer: Codable, Equatable {
    /// The home host's id on the Mac that set it up, so every device names
    /// the same host in SharedStateSync.
    public var hostID: UUID
    public var label: String
    /// Where to connect, as OpenSSH resolved it on the Mac (`ssh -G`): the
    /// real host name, not a ~/.ssh/config alias a phone doesn't have.
    public var address: String
    public var port: Int
    public var user: String
    /// The server's public host key ("ssh-ed25519 AAAA…"): the first
    /// connection from a new device is checked, never trusted blindly.
    public var hostKey: String

    public init(hostID: UUID, label: String, address: String, port: Int, user: String, hostKey: String) {
        self.hostID = hostID
        self.label = label
        self.address = address
        self.port = port
        self.user = user
        self.hostKey = hostKey
    }

    /// The host as the sync addresses it.
    public var hostConfig: HostConfig {
        HostConfig(id: hostID, label: label, ssh: SSHConfig(host: address, user: user, port: port))
    }

    public static func load(from store: SecretStore = .shared) -> HomeHostPointer? {
        let json = store.get(.homeHost)
        guard !json.isEmpty else { return nil }
        return try? JSONDecoder().decode(HomeHostPointer.self, from: Data(json.utf8))
    }

    public func save(to store: SecretStore = .shared) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.set(.homeHost, String(decoding: data, as: UTF8.self))
    }
}

/// Everything a device needs, in one string: for builds whose secrets
/// can't sync through iCloud Keychain (no entitlement), and for setting up
/// a device without waiting for iCloud.
///
/// It carries a credential to the home host, and is treated as one: the
/// Mac shows it only on request, as a QR code a phone's camera opens
/// (`onyx-today://pair?c=…`) or text to copy, and the phone stores what's
/// in it in its keychain and keeps nothing else.
public struct PairingCode: Codable, Equatable {
    public static let scheme = "onyx-today"
    public static let prefix = "onyx1:"

    public var home: HomeHostPointer
    /// The Onyx key, raw Ed25519, base64.
    public var key: String
    /// API tokens by SecretKey raw value. Left out when they'd make the
    /// code too big for a QR code — they reach the phone through iCloud
    /// Keychain, or are entered there.
    public var tokens: [String: String]

    public init(home: HomeHostPointer, key: String, tokens: [String: String]) {
        self.home = home
        self.key = key
        self.tokens = tokens
    }

    /// "onyx1:" and the JSON, base64url.
    public var text: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The link a camera opens.
    public var url: URL? {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "c", value: text)]
        return parts.url
    }

    /// Read a code pasted, typed or opened as a link. Whitespace (a code
    /// wrapped across lines) is ignored.
    public static func parse(_ input: String) -> PairingCode? {
        var candidate = input.filter { !$0.isWhitespace }
        if let url = URLComponents(string: candidate), url.scheme == scheme,
           let c = url.queryItems?.first(where: { $0.name == "c" })?.value {
            candidate = c
        }
        guard candidate.hasPrefix(prefix) else { return nil }
        var base64 = String(candidate.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(PairingCode.self, from: data)
    }

    /// A code with the tokens if it still fits a scannable QR code, and
    /// without them otherwise.
    public static func make(home: HomeHostPointer, key: String, tokens: [String: String],
                            maxLength: Int = 1800) -> (code: PairingCode, tokensIncluded: Bool) {
        let full = PairingCode(home: home, key: key, tokens: tokens.filter { !$0.value.isEmpty })
        if full.url?.absoluteString.count ?? .max <= maxLength { return (full, !full.tokens.isEmpty) }
        return (PairingCode(home: home, key: key, tokens: [:]), false)
    }

    /// Store what's in the code on this device.
    public func install(into store: SecretStore = .shared) {
        store.set(.sshPrivateKey, key)
        home.save(to: store)
        for (name, value) in tokens {
            if let secret = SecretKey(rawValue: name), secret != .sshPrivateKey, secret != .homeHost {
                store.set(secret, value)
            }
        }
    }
}
