//
// DeviceSyncManager.swift
//
// Responsibility: "Sync to iPhone and iPad" — the Mac action that lets a
//                 phone reach the home host: make the Onyx key, put it in
//                 the home host's authorized_keys, prove the phone's SSH
//                 client can sign in with it, and leave the key and the
//                 home host's address and host key in iCloud Keychain.
//                 Turning it off undoes all of that.
// Scope: Shared singleton.
// Threading: The work runs on a utility queue; state is published on main.
//
// docs/ios-plan.md, "How a new device is set up". The proof step matters:
// it signs in with the Onyx key alone, over the built-in client — the one
// the phone has — so a key the server doesn't accept, or a host the
// built-in client can't reach, is found here, on the Mac, where it can be
// fixed, instead of on a phone that just says "can't connect".
//

import Foundation
import OnyxCore
import OnyxSSH

public final class DeviceSyncManager: ObservableObject {

    public static let shared = DeviceSyncManager()

    public enum State: Equatable {
        case off
        case working(String)
        /// On: the phone can find the host. `synced` says whether the
        /// secrets reach other devices through iCloud Keychain (false: this
        /// build can't, so pair with the code).
        case on(HomeHostPointer, synced: Bool)
        case failed(String)
    }

    @Published public private(set) var state: State = .off

    private let queue = DispatchQueue(label: "com.onyx.device-sync", qos: .utility)
    private let secrets: SecretStore

    init(secrets: SecretStore = .shared) {
        self.secrets = secrets
        if let pointer = HomeHostPointer.load(from: secrets), OnyxKey.load(from: secrets) != nil {
            state = .on(pointer, synced: secrets.isSynced(.homeHost))
        }
    }

    public var isOn: Bool {
        if case .on = state { return true }
        return false
    }

    // MARK: - On and off

    /// Make the key, install it on `home`, prove it works, publish it.
    public func enable(home: HostConfig, appState: AppState) {
        state = .working("Installing the Onyx key on \(home.label)…")
        let transport = appState.transport
        queue.async { [secrets] in
            let identity = OnyxKey.loadOrCreate(in: secrets)
            let line = identity.authorizedKeysLine(comment: OnyxKey.comment)
            let install = transport.runScript(Self.installScript(line: line), on: home,
                                              timeout: 20, label: "deviceSync:install")
            guard install.cleaned?.contains("INSTALLED") == true else {
                return self.finish(.failed("couldn't add the key on \(home.label): \(install.failureDetail)"))
            }
            self.publish(.working("Checking the phone's SSH client can sign in…"))
            switch Self.prove(identity: identity, home: home) {
            case .failure(let why):
                self.finish(.failed(why.description))
            case .success(let pointer):
                pointer.save(to: secrets)
                DiagnosticLog.shared.record("config", "device sync on: \(pointer.user)@\(pointer.address):\(pointer.port)")
                self.finish(.on(pointer, synced: secrets.isSynced(.homeHost)))
            }
        }
    }

    /// Remove the key from the home host and the Keychain items with it.
    /// The Keychain goes regardless: a host that can't be reached right
    /// now must not keep the phone signed in.
    public func disable(home: HostConfig?, appState: AppState) {
        let identity = OnyxKey.load(from: secrets)
        state = .working("Removing the Onyx key…")
        let transport = appState.transport
        queue.async { [secrets] in
            var leftover: String?
            if let home, let identity {
                let remove = transport.runScript(Self.removeScript(line: identity.authorizedKeysLine(comment: OnyxKey.comment)),
                                                 on: home, timeout: 20, label: "deviceSync:remove")
                if remove.cleaned?.contains("REMOVED") != true {
                    leftover = "the key is still in \(home.label)'s authorized_keys (\(remove.failureDetail)); "
                        + "remove the line ending \(OnyxKey.comment) by hand"
                }
            }
            secrets.set(.homeHost, "")
            secrets.set(.sshPrivateKey, "")
            self.finish(leftover.map { .failed($0) } ?? .off)
        }
    }

    /// The code for a phone that can't get the secrets from iCloud.
    public func pairingCode() -> (code: PairingCode, tokensIncluded: Bool)? {
        guard case .on(let pointer, _) = state else { return nil }
        let key = secrets.get(.sshPrivateKey)
        guard !key.isEmpty else { return nil }
        var tokens: [String: String] = [:]
        for secret in [SecretKey.githubToken, .gitlabToken, .timingToken, .flowtreeClientSecret] {
            tokens[secret.rawValue] = secrets.get(secret)
        }
        return PairingCode.make(home: pointer, key: key, tokens: tokens)
    }

    // MARK: - The proof

    /// Sign in to `home` the way the phone will — built-in client, Onyx
    /// key only — and learn its address and host key while doing it.
    static func prove(identity: SSHIdentity, home: HostConfig) -> Result<HomeHostPointer, Failure> {
        let resolved: ResolvedHost
        do {
            resolved = try OpenSSHConfigResolver.shared.resolve(home)
        } catch {
            return .failure(Failure("\(home.label) \(error)"))
        }
        // OpenSSH's known_hosts decides whether the key is the right one;
        // our own copy of it only records what was seen.
        let seen = KnownHostsStore(url: nil, openSSHFiles: KnownHostsStore.userOpenSSHFiles)
        let probe = NIOTransport(knownHosts: seen, connectTimeout: 10,
                                 resolver: { _ in resolved }, identities: { _ in ([identity], []) })
        defer { probe.disconnectAll() }
        let out = probe.runCommand("echo onyx-$((40+2))", on: home, timeout: 15, label: "deviceSync:prove")
        guard out.exit == 0, out.stdout.contains("onyx-42") else {
            return .failure(Failure("the phone's SSH client couldn't sign in to \(home.label): "
                                    + (out.stderr.isEmpty ? "exit \(out.exit)" : out.stderr)))
        }
        guard let hostKey = seen.key(host: resolved.hostName, port: resolved.port) else {
            return .failure(Failure("signed in to \(home.label) but didn't see its host key"))
        }
        return .success(HomeHostPointer(hostID: home.id, label: home.label, address: resolved.hostName,
                                        port: resolved.port, user: resolved.user, hostKey: hostKey))
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Scripts

    /// Add the line once, keeping authorized_keys and ~/.ssh private.
    /// The key text is base64 — no quote can appear in it.
    static func installScript(line: String) -> String {
        let key = line.split(separator: " ").prefix(2).joined(separator: " ")
        return "D=\"$HOME/.ssh\"; F=\"$D/authorized_keys\"; mkdir -p \"$D\" && chmod 700 \"$D\" "
            + "&& touch \"$F\" && chmod 600 \"$F\" "
            + "&& { grep -qF '\(key)' \"$F\" || echo '\(line)' >> \"$F\"; } && echo INSTALLED"
    }

    /// Drop the line, in place (`cat >` keeps the file's owner and mode).
    static func removeScript(line: String) -> String {
        let key = line.split(separator: " ").prefix(2).joined(separator: " ")
        return "F=\"$HOME/.ssh/authorized_keys\"; T=\"$F.onyx-tmp\"; "
            + "if [ -f \"$F\" ]; then grep -vF '\(key)' \"$F\" > \"$T\"; cat \"$T\" > \"$F\"; rm -f \"$T\"; fi; "
            + "echo REMOVED"
    }

    // MARK: - State

    private func publish(_ next: State) {
        DispatchQueue.main.async { self.state = next }
    }

    private func finish(_ next: State) {
        if case .failed(let why) = next {
            DiagnosticLog.shared.record("config", "device sync: \(why)", failure: true)
        }
        publish(next)
    }
}
