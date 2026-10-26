//
// BuiltInSSH.swift
//
// Responsibility: The Mac's copy of the in-process SSH client (OnyxSSH's
//                 NIOTransport) — the one the iPhone and iPad have no
//                 alternative to — configured the way the user's OpenSSH
//                 is: their ~/.ssh/config, their key files, their
//                 known_hosts.
// Scope: One per app.
// Threading: `resolve` launches `ssh -G`, bounded; call it off main, as
//            every transport call already is.
//
// Why `ssh -G` rather than parsing ~/.ssh/config ourselves: Include,
// Match, wildcards and token expansion make that file a language, and
// OpenSSH will evaluate it for us exactly as it would for a connection.
//

import Foundation
import OnyxCore
import OnyxSSH

enum BuiltInSSH {

    static let transport = NIOTransport(
        resolver: { try OpenSSHConfigResolver.shared.resolve($0) },
        identities: { host in
            var usable: [SSHIdentity] = []
            if let onyx = OnyxKey.load() { usable.append(onyx) }
            let files = (try? OpenSSHConfigResolver.shared.resolve(host))?.identityFiles
                ?? [host.ssh.identityFile, "~/.ssh/id_ed25519", "~/.ssh/id_ecdsa"].filter { !$0.isEmpty }
            let found = OpenSSHKeyFile.userKeys(at: files)
            return (usable + found.usable, found.skipped)
        })
}

/// What `ssh -G` says a host means: HostName, User, Port, IdentityFile.
final class OpenSSHConfigResolver {

    static let shared = OpenSSHConfigResolver()

    struct Unsupported: Error, CustomStringConvertible {
        let description: String
    }

    private let lock = NSLock()
    private var cache: [String: (ResolvedHost, Date)] = [:]
    /// ~/.ssh/config rarely changes; a minute keeps an edit from needing a
    /// restart without running ssh for every call.
    private let lifetime: TimeInterval = 60

    /// The arguments for `ssh -G`, built as every other ssh command here
    /// is: -p only off 22, -i only when set, user@host when there's a user.
    static func arguments(for host: HostConfig) -> [String] {
        var args = ["-G"]
        if host.ssh.port != 22 { args += ["-p", "\(host.ssh.port)"] }
        if !host.ssh.identityFile.isEmpty { args += ["-i", host.ssh.identityFile] }
        args.append(host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)")
        return args
    }

    /// Parse `ssh -G` output. Throws for configurations the built-in
    /// client can't follow, rather than connecting somewhere else.
    static func parse(_ output: String) throws -> ResolvedHost {
        var values: [String: String] = [:]
        var identityFiles: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if key == "identityfile" { identityFiles.append(parts[1]) } else if values[key] == nil { values[key] = parts[1] }
        }
        for key in ["proxyjump", "proxycommand"] {
            if let v = values[key], v.lowercased() != "none" {
                throw Unsupported(description: "reaches this host through \(key == "proxyjump" ? "ProxyJump" : "ProxyCommand"), which the built-in client can't follow yet")
            }
        }
        guard let hostName = values["hostname"], let user = values["user"] else {
            throw Unsupported(description: "ssh -G gave no host name")
        }
        return ResolvedHost(hostName: hostName, port: Int(values["port"] ?? "") ?? 22,
                            user: user, identityFiles: identityFiles)
    }

    func resolve(_ host: HostConfig) throws -> ResolvedHost {
        let args = Self.arguments(for: host)
        let key = args.joined(separator: " ")
        lock.lock()
        if let (hit, at) = cache[key], Date().timeIntervalSince(at) < lifetime {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let run = RemoteExec.shared.run("/usr/bin/ssh", args: args, softTimeout: 5,
                                        captureStdout: true, captureStderr: true, label: "ssh -G")
        guard run.exit == 0 else {
            throw Unsupported(description: "ssh -G failed: \(run.stderr)")
        }
        let resolved = try Self.parse(run.stdout)
        lock.lock()
        cache[key] = (resolved, Date())
        lock.unlock()
        return resolved
    }
}
