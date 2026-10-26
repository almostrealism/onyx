//
// TodayModel.swift
//
// Responsibility: The whole of Onyx Today's state on an iPhone — the
//                 Today sections' TodayState, the home host the shared
//                 state comes from, and the built-in SSH client that
//                 reaches it — with no AppState, because a phone has none
//                 of what one owns (docs/ios-plan.md, phase 3).
// Scope: One per app.
// Threading: Main thread; the sync does its own work off it.
//
// The phone is a reader of the shared state that can also write: it
// adopts the settings, pipelines and notes the Macs share, and a setting
// changed here (the agenda pane, the draft filter) travels back the same
// way. It publishes no hosts — it has none.
//

import Foundation
import Combine
import SwiftUI
import OnyxCore
import OnyxSSH
import OnyxUI

public final class TodayModel: ObservableObject, SharedStateEnvironment {

    public let today = TodayState(windowIndex: 0)
    /// Where the shared state lives; nil until this phone is paired.
    @Published public private(set) var home: HomeHostPointer?
    /// Why the last pairing attempt didn't take.
    @Published public var pairingProblem: String?

    public let transport: NIOTransport
    private let secrets: SecretStore
    private var frontmost = true
    private var cancellables: Set<AnyCancellable> = []
    private var keychainPoll: Timer?

    public init(directory: URL? = nil, secrets: SecretStore = .shared) {
        self.secrets = secrets
        // The Mac's feature tips name its keys.
        FeatureTipLine.enabled = false
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AppearanceStore.shared.configure(url: support.appendingPathComponent("appearance.json"))
        SessionNotesStore.shared.configure(url: support.appendingPathComponent("session-notes.json"))
        FavoritesStore.shared.configure(url: support.appendingPathComponent("favorites.json"))

        transport = NIOTransport(knownHosts: .shared, connectTimeout: 15, identities: { _ in
            guard let key = OnyxKey.load(from: secrets) else {
                return ([], ["no Onyx key yet — pair this phone with your Mac"])
            }
            return ([key], [])
        })

        SharedStateSync.shared.configure(url: support.appendingPathComponent("shared-state-sync.json"),
                                         environment: self)
        SharedStateSync.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        today.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        adoptHomeFromKeychain()
        #if DEBUG
        // For the simulator, which can't tap "Open" on a pairing link:
        // `SIMCTL_CHILD_ONYX_TODAY_PAIRING_CODE=onyx1:… xcrun simctl launch …`.
        if let code = ProcessInfo.processInfo.environment["ONYX_TODAY_PAIRING_CODE"] {
            pair(with: code)
        }
        #endif
        TodayState.startServices()
    }

    // MARK: - Pairing

    /// Pick up the home host from iCloud Keychain, where the Mac's "Sync
    /// to iPhone and iPad" put it. Until it arrives, look again now and
    /// then — iCloud delivers in its own time.
    public func adoptHomeFromKeychain() {
        secrets.reload()
        guard let pointer = HomeHostPointer.load(from: secrets), OnyxKey.load(from: secrets) != nil else {
            startWaitingForKeychain()
            return
        }
        use(pointer)
    }

    /// Pair from a code (pasted, typed, or opened from the Mac's QR code).
    @discardableResult
    public func pair(with input: String) -> Bool {
        guard let code = PairingCode.parse(input) else {
            pairingProblem = "That isn't an Onyx pairing code. On your Mac: Settings → Shared state → Show pairing code."
            return false
        }
        code.install(into: secrets)
        pairingProblem = nil
        use(code.home)
        return true
    }

    /// A link opened by the system: the Mac's QR code, through the Camera.
    public func open(_ url: URL) {
        guard url.scheme == PairingCode.scheme else { return }
        pair(with: url.absoluteString)
    }

    private func use(_ pointer: HomeHostPointer) {
        keychainPoll?.invalidate()
        keychainPoll = nil
        // The first connection is checked against the key the Mac saw,
        // never trusted on sight.
        KnownHostsStore.shared.pin(host: pointer.address, port: pointer.port, key: pointer.hostKey)
        let changed = home != pointer
        home = pointer
        if SharedStateSync.shared.homeHostID != pointer.hostID {
            SharedStateSync.shared.setHomeHost(pointer.hostID)
        } else if changed {
            SharedStateSync.shared.syncNow()
        }
        // Tokens may have arrived with it.
        TodayState.refreshServices()
    }

    private func startWaitingForKeychain() {
        guard keychainPoll == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.home == nil else { return }
            self.secrets.reload()
            if let pointer = HomeHostPointer.load(from: self.secrets), OnyxKey.load(from: self.secrets) != nil {
                self.use(pointer)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keychainPoll = timer
    }

    // MARK: - Foreground

    /// The scene came to the front or went away.
    public func setFrontmost(_ active: Bool) {
        frontmost = active
        guard active else { return }
        if home == nil { adoptHomeFromKeychain() }
        SharedStateSync.shared.appDidBecomeActive()
        TodayState.refreshServices()
    }

    // MARK: - Status

    public var syncStatusLine: String {
        guard let home else { return "Not paired with a home host yet." }
        let sync = SharedStateSync.shared
        return SharedStateSync.statusLine(sync.status, hostLabel: home.label, lastWrittenBy: sync.lastWrittenBy)
    }

    public var syncFailed: Bool {
        if case .failed = SharedStateSync.shared.status { return true }
        return false
    }

    // MARK: - SharedStateEnvironment

    public var sharedStateHosts: [HostConfig] { home.map { [$0.hostConfig] } ?? [] }
    public var syncTransport: RemoteTransport { transport }
    public func canSync(with host: HostConfig) -> Bool { home != nil && OnyxKey.load(from: secrets) != nil }
    public func claimSyncSlot(for host: HostConfig) -> (() -> Void)? { {} }
    /// The next sync reconnects by itself; there's no pair to fail over.
    public func syncConnectionFailed(host: HostConfig) { transport.disconnect(host) }
    public var isFrontmost: Bool { frontmost }
    public var ownHosts: [HostConfig]? { nil }
}
