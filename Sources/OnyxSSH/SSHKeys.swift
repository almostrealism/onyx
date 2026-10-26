//
// SSHKeys.swift
//
// Responsibility: The keys the in-process client signs in with — the Onyx
//                 key (Ed25519, made by Onyx, kept in SecretStore and
//                 synced through iCloud Keychain) and, on a Mac, the
//                 user's own unencrypted OpenSSH key files.
// Scope: Value types and pure parsing.
//
// Ed25519 and ECDSA only, never RSA (docs/ios-plan.md, "No RSA keys"):
// SwiftNIO SSH can't sign with RSA, and the iOS apps use the Onyx key
// anyway. An RSA or passphrase-protected file is skipped with a reason
// rather than failing the connection — the next key may work.
//

import Foundation
import Crypto
import NIOSSH
import OnyxCore

public struct SSHIdentity {
    public let privateKey: NIOSSHPrivateKey
    /// Where it came from, for logs ("the Onyx key", "~/.ssh/id_ed25519").
    public let source: String

    public init(privateKey: NIOSSHPrivateKey, source: String) {
        self.privateKey = privateKey
        self.source = source
    }

    /// The line for a host's `authorized_keys`.
    public func authorizedKeysLine(comment: String) -> String {
        String(openSSHPublicKey: privateKey.publicKey) + " " + comment
    }
}

/// The Onyx key: one Ed25519 key per user, every device.
public enum OnyxKey {

    /// The comment on its `authorized_keys` line, so it can be found and
    /// removed on its own.
    public static let comment = "onyx-sync"

    /// The key in SecretStore, or nil before "Sync to iPhone and iPad"
    /// was turned on.
    public static func load(from store: SecretStore = .shared) -> SSHIdentity? {
        let encoded = store.get(.sshPrivateKey)
        guard !encoded.isEmpty, let raw = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return SSHIdentity(privateKey: NIOSSHPrivateKey(ed25519Key: key), source: "the Onyx key")
    }

    /// The stored key, made and stored first if there isn't one.
    @discardableResult
    public static func loadOrCreate(in store: SecretStore = .shared) -> SSHIdentity {
        if let existing = load(from: store) { return existing }
        let key = Curve25519.Signing.PrivateKey()
        store.set(.sshPrivateKey, key.rawRepresentation.base64EncodedString())
        return SSHIdentity(privateKey: NIOSSHPrivateKey(ed25519Key: key), source: "the Onyx key")
    }
}

/// OpenSSH private key files (`-----BEGIN OPENSSH PRIVATE KEY-----`).
public enum OpenSSHKeyFile {

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notOpenSSHFormat
        case encrypted
        case unsupportedKeyType(String)
        case malformed

        public var description: String {
            switch self {
            case .notOpenSSHFormat: return "not an OpenSSH private key"
            case .encrypted: return "protected by a passphrase"
            case .unsupportedKeyType(let t): return "a \(t) key, which the built-in client can't use"
            case .malformed: return "unreadable"
            }
        }
    }

    public static func parse(_ text: String) throws -> NIOSSHPrivateKey {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else {
            throw ParseError.notOpenSSHFormat
        }
        let base64 = text[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else { throw ParseError.malformed }
        var r = SSHWireReader(data)

        let magic = Array("openssh-key-v1".utf8) + [0]
        guard r.bytes(magic.count) == Data(magic) else { throw ParseError.notOpenSSHFormat }
        guard let cipher = r.string(), let kdf = r.string(), r.data() != nil,
              let count = r.uint32(), count == 1, r.data() != nil,
              let privateBlock = r.data() else { throw ParseError.malformed }
        guard cipher == "none", kdf == "none" else { throw ParseError.encrypted }

        var p = SSHWireReader(privateBlock)
        guard let check1 = p.uint32(), let check2 = p.uint32(), check1 == check2,
              let type = p.string() else { throw ParseError.malformed }
        switch type {
        case "ssh-ed25519":
            // public key (32), then private: seed (32) || public (32)
            guard p.data() != nil, let secret = p.data(), secret.count == 64,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)) else {
                throw ParseError.malformed
            }
            return NIOSSHPrivateKey(ed25519Key: key)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            // curve name, public point, private scalar (an mpint)
            guard p.string() != nil, p.data() != nil, var scalar = p.data() else { throw ParseError.malformed }
            while scalar.first == 0, scalar.count > 1 { scalar.removeFirst() }   // mpint sign byte
            do {
                switch type {
                case "ecdsa-sha2-nistp256":
                    return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: pad(scalar, 32)))
                case "ecdsa-sha2-nistp384":
                    return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: pad(scalar, 48)))
                default:
                    return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: pad(scalar, 66)))
                }
            } catch {
                throw ParseError.malformed
            }
        default:
            throw ParseError.unsupportedKeyType(type)
        }
    }

    private static func pad(_ data: Data, _ length: Int) -> Data {
        data.count >= length ? data.suffix(length) : Data(repeating: 0, count: length - data.count) + data
    }

    #if os(macOS)
    /// The user's own keys for a host, in the order OpenSSH would try them:
    /// the host's IdentityFile, then the standard names. Files that can't be
    /// used come back as reasons, so a failed sign-in can say why.
    public static func userKeys(for host: HostConfig,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (usable: [SSHIdentity], skipped: [String]) {
        var paths: [String] = []
        if !host.ssh.identityFile.isEmpty { paths.append(host.ssh.identityFile) }
        for name in ["id_ed25519", "id_ecdsa"] {
            paths.append(home.appendingPathComponent(".ssh/\(name)").path)
        }
        return userKeys(at: paths, home: home)
    }

    /// The keys in these files, in order; missing files are passed over
    /// quietly (OpenSSH lists its default names whether or not they exist).
    public static func userKeys(at paths: [String],
                                home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> (usable: [SSHIdentity], skipped: [String]) {
        var usable: [SSHIdentity] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for raw in paths {
            let path = raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))).path : raw
            guard seen.insert(path).inserted,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let shown = path.replacingOccurrences(of: home.path, with: "~")
            do {
                usable.append(SSHIdentity(privateKey: try parse(text), source: shown))
            } catch {
                skipped.append("\(shown) is \(error)")
            }
        }
        return (usable, skipped)
    }
    #endif
}

/// Reads SSH wire encoding (RFC 4251 §5) out of Data.
struct SSHWireReader {
    private let buffer: Data
    private var offset: Int

    init(_ data: Data) {
        self.buffer = Data(data)   // re-based, so indices start at 0
        self.offset = 0
    }

    var remaining: Int { buffer.count - offset }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return buffer.subdata(in: offset..<offset + n)
    }

    mutating func byte() -> UInt8? { bytes(1)?.first }

    mutating func uint32() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return b.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func uint64() -> UInt64? {
        guard let b = bytes(8) else { return nil }
        return b.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func data() -> Data? {
        guard let n = uint32() else { return nil }
        return bytes(Int(n))
    }

    mutating func string() -> String? {
        data().flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Writes SSH wire encoding into Data.
struct SSHWireWriter {
    private(set) var data = Data()

    mutating func byte(_ b: UInt8) { data.append(b) }

    mutating func uint32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    mutating func uint64(_ v: UInt64) {
        uint32(UInt32(v >> 32))
        uint32(UInt32(v & 0xffff_ffff))
    }

    mutating func data(_ d: Data) {
        uint32(UInt32(d.count))
        data.append(d)
    }

    mutating func string(_ s: String) { data(Data(s.utf8)) }
}
