//
// SharedStateSync.swift
//
// Responsibility: Keeping session notes and favourites on a chosen remote
//                 host, so every Mac running Onyx sees the same set.
// Scope: Shared singleton. Owns the home-host choice, the shadow copy of
//        what was last synced, and the transfer.
// Threading: transfers on a utility queue; stores and @Published state on
//            main. Nothing here blocks the UI.
//
// The local files stay the working copy, always. The remote file is a
// meeting point, not the source of truth — so an unreachable host, a
// paused host or no host at all means Onyx works exactly as it did
// before, with a status line saying why. There is no mode in which your
// notes live somewhere you can't read them.
//
// The transfer is deliberately dumb: pull the whole file, merge it in
// memory (SharedStateMerge), push the whole file back if the result
// differs. It is a few kilobytes of JSON and a handful of entries; a
// smarter protocol would only add ways to lose a note.
//
// scp, not a remote script. The state is far past the ~1KB ceiling an
// interactive remote shell can be fed (see CLAUDE.md), and a truncated
// shared-state.json is the worst outcome available — so the payload
// travels as a file and the only scripts are a mkdir and an atomic mv.
//

import Foundation
import Combine

public final class SharedStateSync: ObservableObject {
    public static let shared = SharedStateSync()

    /// Where the bundle lives on the home host. Under `~/.onyx/` with the
    /// rest of what Onyx puts on a host — and a path with no spaces, which
    /// the mux sockets taught us to care about.
    public static let remoteDirectory = "$HOME/.onyx"
    public static let remoteFilename = "shared-state.json"

    public enum Status: Equatable {
        /// No home host: this Mac only. The default.
        case localOnly
        /// A transfer is in flight.
        case syncing
        /// Last sync succeeded at this time.
        case synced(Date)
        /// The host isn't reachable right now (down, asleep, paused). Not
        /// an error — the local copy is authoritative and we'll try again.
        case waitingForHost
        /// Something went wrong, in the remote's words where we have them.
        case failed(String)
    }

    @Published public private(set) var status: Status = .localOnly
    /// nil = this Mac only. Main-thread mirror of `storedHome`, which is
    /// what the transfer queue reads.
    @Published public private(set) var homeHostID: UUID?
    /// Who wrote the copy we last pulled, for the status line.
    @Published public private(set) var lastWrittenBy: String?

    private weak var appState: AppState?
    private var url: URL?
    /// Lock-guarded copy of the home host, readable off main.
    private var storedHome: UUID?
    private var shadow: SharedState?
    private var lastSync: Date?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.onyx.shared-state", qos: .utility)
    private var timer: Timer?
    private var watches: Set<AnyCancellable> = []
    private var pushPending = false
    /// True while we are applying merged state to the stores, so the
    /// change notifications that causes don't schedule another sync.
    private var applying = false

    private init() {}

    // MARK: - Wiring

    private struct Record: Codable {
        var homeHostID: UUID?
        var shadow: SharedState?
        var lastSync: Date?
    }

    public func configure(url: URL, appState: AppState) {
        lock.lock()
        let alreadyConfigured = self.url != nil
        if !alreadyConfigured {
            self.url = url
            if let data = try? Data(contentsOf: url),
               let record = try? JSONDecoder().decode(Record.self, from: data) {
                shadow = record.shadow
                lastSync = record.lastSync
                storedHome = record.homeHostID
                let home = record.homeHostID
                DispatchQueue.main.async {
                    self.homeHostID = home
                    self.status = home == nil ? .localOnly : .waitingForHost
                }
            }
        }
        lock.unlock()
        if self.appState == nil { self.appState = appState }
        guard !alreadyConfigured else { return }

        // Local edits schedule a push. Debounced, because typing a note
        // publishes on every keystroke and each push is three round trips.
        SessionNotesStore.shared.$notes
            .map { _ in () }
            .merge(with: FavoritesStore.shared.$entries.map { _ in () })
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.localChanged() }
            .store(in: &watches)

        start()
    }

    private func start() {
        guard timer == nil else { return }
        // Two minutes. The remote file only changes when another Mac
        // writes it, and a slow pickup of someone else's note costs
        // nothing; a tight poll costs a channel on every host every tick.
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            self?.sync(reason: "tick")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sync(reason: "launch")
    }

    // MARK: - The home host

    public func homeHost(in hosts: [HostConfig]) -> HostConfig? {
        guard let homeHostID else { return nil }
        return hosts.first { $0.id == homeHostID }
    }

    /// Change where the shared state lives.
    ///
    /// Never an adoption: the new home's copy and this Mac's copy are
    /// UNIONED, because the user asked to share two sets of notes, not to
    /// pick which one survives. Dropping the shadow is what makes that
    /// happen — with no shadow the merge applies no deletions at all.
    public func setHomeHost(_ hostID: UUID?) {
        lock.lock()
        storedHome = hostID
        shadow = nil
        lastSync = nil
        persist()
        lock.unlock()
        homeHostID = hostID
        lastWrittenBy = nil
        status = hostID == nil ? .localOnly : .syncing
        guard hostID != nil else { return }
        sync(reason: "home host changed")
    }

    private func localChanged() {
        guard !applying, homeHostID != nil else { return }
        sync(reason: "local edit")
    }

    public func syncNow() { sync(reason: "user asked") }

    // MARK: - Syncing

    private func sync(reason: String) {
        guard let appState else { return }
        lock.lock(); let home = storedHome; lock.unlock()
        guard let home else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.claimRun() else { return }
            defer { self.finishRun() }

            let hosts = DispatchQueue.main.sync { appState.hosts }
            guard let host = hosts.first(where: { $0.id == home }) else {
                // The host was deleted from Settings. Say so rather than
                // silently reverting to local-only, which looks like the
                // setting didn't stick.
                self.report(.failed("the host this was synced to is no longer configured"))
                return
            }
            guard appState.hostUsable(host) else {
                self.report(.waitingForHost)
                return
            }
            guard let release = appState.acquireUtilityChannel("sharedState:\(host.id)",
                                                              host: host) else {
                self.report(.waitingForHost)
                return
            }
            defer { release() }

            DispatchQueue.main.async { self.status = .syncing }
            self.run(host: host, appState: appState, reason: reason)
        }
    }

    /// One run at a time. The timer, a local edit and the user's button
    /// can all fire at once, and two overlapping runs would push each
    /// other's intermediate merges.
    private var running = false
    private func claimRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return true }
        running = true
        return false
    }
    private func finishRun() {
        lock.lock(); running = false; lock.unlock()
    }

    private func run(host: HostConfig, appState: AppState, reason: String) {
        let local = currentLocalState()
        let fetched = fetch(host: host, appState: appState)
        switch fetched {
        case .failure(let message):
            report(.failed(message))
            return
        case .success(let remote):
            lock.lock(); let base = shadow; lock.unlock()
            let merged = SharedStateMerge.merge(base: base, local: local,
                                                remote: remote ?? .empty)

            // Apply to the stores first: even if the push fails, the user
            // gets the other machine's notes, and the next run retries.
            apply(merged)

            // Only write when the host's copy would actually change —
            // otherwise two Macs on a timer rewrite the file at each other
            // forever, for nothing.
            if let remote, merged.sameContent(as: remote) {
                // Nothing to send.
            } else if !push(merged, host: host, appState: appState) {
                return
            }

            lock.lock()
            shadow = merged
            lastSync = Date()
            let stamp = lastSync!
            persist()
            lock.unlock()
            let writer = remote?.writtenBy
            DispatchQueue.main.async {
                self.lastWrittenBy = writer?.isEmpty == false ? writer : nil
                self.status = .synced(stamp)
            }
            DiagnosticLog.shared.record(
                "config",
                "shared state synced with \(host.label) (\(reason)): "
                + "\(merged.notes.count) notes, \(merged.favorites.count) favourites")
        }
    }

    private func currentLocalState() -> SharedState {
        let snapshot: ([String: SessionNote], [FavoriteEntry]) = DispatchQueue.main.sync {
            (SessionNotesStore.shared.notes, FavoritesStore.shared.entries)
        }
        return SharedState(notes: snapshot.0, favorites: snapshot.1,
                           updated: Date(), writtenBy: Self.thisMachine)
    }

    private func apply(_ state: SharedState) {
        DispatchQueue.main.sync {
            applying = true
            SessionNotesStore.shared.replaceAll(state.notes)
            if FavoritesStore.shared.entries != state.favorites {
                FavoritesStore.shared.entries = state.favorites
                FavoritesStore.shared.save()
            }
            applying = false
        }
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.status = status }
    }

    /// Must hold `lock`.
    private func persist() {
        guard let url else { return }
        let record = Record(homeHostID: homeHostID, shadow: shadow, lastSync: lastSync)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url)
    }

    static var thisMachine: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: - Transfer

    private enum Fetched {
        /// nil = the host has no copy yet, which is the normal first run.
        case success(SharedState?)
        case failure(String)
    }

    private var scratch: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-shared-state-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    private func fetch(host: HostConfig, appState: AppState) -> Fetched {
        let local = scratch
        try? FileManager.default.removeItem(at: local)
        let remote = "\(Self.remoteDirectory)/\(Self.remoteFilename)"
        let (cmd, args) = appState.scpFetchCommand(remotePath: remote,
                                                   localPath: local.path, host: host)
        let result = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 30,
                                           captureStdout: true, captureStderr: true,
                                           label: "sharedStatePull:\(host.label)")
        defer { try? FileManager.default.removeItem(at: local) }

        guard let data = try? Data(contentsOf: local) else {
            // scp says 1 for "no such file" and 255 for a connection
            // problem. The first is a host that simply hasn't been written
            // to yet — the common case on the very first sync — and must
            // not be reported as an error.
            if result.exit == 255 {
                appState.reportSSHFailure(host: host)
                return .failure(Self.shortError(result.stderr) ?? "couldn't reach \(host.label)")
            }
            let complaint = Self.shortError(result.stderr)
            if let complaint, !complaint.lowercased().contains("no such file") {
                return .failure(complaint)
            }
            return .success(nil)
        }
        guard let decoded = try? JSONDecoder().decode(SharedState.self, from: data) else {
            // Refuse to overwrite something we can't read. Silently
            // replacing it would destroy whatever a future version of
            // Onyx — or a half-finished transfer — left there.
            return .failure("the copy on \(host.label) isn't readable; not touching it")
        }
        return .success(decoded)
    }

    private func push(_ state: SharedState, host: HostConfig, appState: AppState) -> Bool {
        let local = scratch
        guard let data = try? JSONEncoder().encode(state),
              (try? data.write(to: local)) != nil else {
            report(.failed("couldn't stage the file locally"))
            return false
        }
        defer { try? FileManager.default.removeItem(at: local) }

        // The directory may not exist yet; scp won't make it.
        let mkdir = FileBrowserManager.runScriptWithFallback(
            "mkdir -p \"$HOME/.onyx\" && echo READY", appState: appState, host: host, timeout: 20)
        guard mkdir.cleaned?.contains("READY") == true else {
            report(.failed(mkdir.failureDetail))
            return false
        }

        // Upload beside the real file, then move it into place. scp writes
        // in the clear: an interrupted transfer straight onto the
        // destination leaves a truncated file, and a truncated
        // shared-state.json read by the next Mac is every note gone.
        let staged = "\(Self.remoteDirectory)/\(Self.remoteFilename).incoming"
        let (cmd, args) = appState.scpCommandAbsolute(localPath: local.path,
                                                      remotePath: staged, host: host)
        let upload = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 30,
                                           captureStdout: true, captureStderr: true,
                                           label: "sharedStatePush:\(host.label)")
        guard upload.exit == 0 else {
            if upload.exit == 255 { appState.reportSSHFailure(host: host) }
            report(.failed(Self.shortError(upload.stderr) ?? "couldn't write to \(host.label)"))
            return false
        }

        let move = FileBrowserManager.runScriptWithFallback(
            "mv \"$HOME/.onyx/\(Self.remoteFilename).incoming\" "
            + "\"$HOME/.onyx/\(Self.remoteFilename)\" && echo MOVED",
            appState: appState, host: host, timeout: 20)
        guard move.cleaned?.contains("MOVED") == true else {
            report(.failed(move.failureDetail))
            return false
        }
        return true
    }

    /// The one line of an scp failure worth showing. scp is chatty and
    /// leads with banner text on hosts that print one.
    static func shortError(_ stderr: String) -> String? {
        let lines = stderr
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Prefer a line that names the failure over the first line, which
        // on a host with a login banner is the banner.
        let interesting = lines.first {
            let l = $0.lowercased()
            return l.contains("no such") || l.contains("denied") || l.contains("refused")
                || l.contains("timed out") || l.contains("not a directory")
                || l.contains("permission") || l.contains("lost connection")
        }
        guard let line = interesting ?? lines.last else { return nil }
        return String(line.prefix(160))
    }

    // MARK: - Status text

    /// What the settings panel shows under the picker.
    public static func statusLine(_ status: Status, hostLabel: String?,
                                 lastWrittenBy: String?, now: Date = Date()) -> String {
        switch status {
        case .localOnly:
            return "Notes and favourites are stored on this Mac only."
        case .syncing:
            return "Syncing with \(hostLabel ?? "the host")…"
        case .waitingForHost:
            return "Waiting for \(hostLabel ?? "the host") — using the copy on this Mac."
        case .failed(let why):
            return "Not synced: \(why). The copy on this Mac is unaffected."
        case .synced(let at):
            var line = "Synced \(ago(at, now: now)) with \(hostLabel ?? "the host")"
            if let by = lastWrittenBy, by != thisMachine {
                line += ", last written by \(by)"
            }
            return line + "."
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 5400 { return "\(max(1, Int((Double(seconds) / 60).rounded()))) min ago" }
        let hours = Int((Double(seconds) / 3600).rounded())
        if hours < 36 { return "\(hours)h ago" }
        return "\(Int((Double(seconds) / 86400).rounded()))d ago"
    }
}
