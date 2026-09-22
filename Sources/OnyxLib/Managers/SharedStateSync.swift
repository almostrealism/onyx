//
// SharedStateSync.swift
//
// Responsibility: Keeping session notes and favorites on a chosen remote
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
import AppKit
import Combine

public final class SharedStateSync: ObservableObject {
    public static let shared = SharedStateSync()

    /// Where the bundle lives on the home host: `~/.onyx/`, with the rest
    /// of what Onyx puts on a host, and no spaces in the path — which the
    /// mux sockets taught us to care about.
    ///
    /// TWO spellings, and they are not interchangeable. scp has spoken
    /// SFTP since OpenSSH 9.0: there is no remote shell in the transfer,
    /// so `$HOME` arrives at the far end as four literal characters and
    /// the copy fails with "No such file or directory". A RELATIVE path is
    /// what works — the SFTP session starts in the user's home directory.
    ///
    /// The shell scripts (mkdir, mv) do run in a shell, and use `$HOME`
    /// because a script should not assume its working directory.
    public static let remoteFilename = "shared-state.json"
    /// For scp. Relative to the remote home directory.
    public static let remotePath = ".onyx/\(remoteFilename)"
    /// For scp, before the atomic move into place.
    public static let remoteStagingPath = "\(remotePath).incoming"
    /// The previous copy, kept on the host. For scp, when restoring.
    public static let remoteBackupPath = ".onyx/shared-state.backup.json"
    /// For shell scripts only.
    public static let remoteDirectoryScript = "$HOME/.onyx"

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
    /// When a run last STARTED, successful or not. Drives the back-off;
    /// `lastSync` records success and is what the status line reads.
    private var lastAttemptAt: Date?
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
        // The forge stores publish objectWillChange for any of their
        // fields, tokens included — a token change simply produces a sync
        // that finds no content difference and pushes nothing.
        SessionNotesStore.shared.$notes
            .map { _ in () }
            .merge(with: FavoritesStore.shared.$entries.map { _ in () },
                   GitHubConfigStore.shared.objectWillChange.map { _ in () },
                   GitLabConfigStore.shared.objectWillChange.map { _ in () },
                   WorkflowFilterStore.shared.includedChanged)
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.localChanged() }
            .store(in: &watches)

        start()
    }

    /// How often the home host is checked for someone else's changes.
    ///
    /// The budget is end-to-end: a note written on one Mac should be on
    /// the other inside about a minute. That splits into a 4-second
    /// write-side debounce (typing publishes on every keystroke and each
    /// push is three round trips) and this poll, so the worst case is
    /// roughly `active + 4` seconds and the average about half of it.
    ///
    /// The back-off matters as much as the interval. A Mac nobody is
    /// looking at has nothing to show, so polling it every minute spends a
    /// channel on every host for a screen no one can see — and the machine
    /// you walk BACK to syncs the moment it is activated, which is the
    /// case that actually feels slow.
    public enum Cadence {
        /// While the app is frontmost.
        public static let active: TimeInterval = 60
        /// While it isn't.
        public static let idle: TimeInterval = 300
        /// Don't re-sync on every ⌘-tab.
        public static let activationThrottle: TimeInterval = 10

        /// Whether a tick should do anything. Pure, so the policy can be
        /// asserted without waiting five minutes for a timer.
        public static func shouldRun(now: Date, lastAttempt: Date?,
                                     isActive: Bool) -> Bool {
            guard let lastAttempt else { return true }
            let elapsed = now.timeIntervalSince(lastAttempt)
            return elapsed >= (isActive ? active : idle)
        }
    }

    private func start() {
        guard timer == nil else { return }
        // Ticks at the ACTIVE interval and decides inside whether this one
        // counts — one timer, and the idle back-off is a policy rather
        // than a second schedule to keep in sync with the first.
        let timer = Timer(timeInterval: Cadence.active, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Coming back to a Mac is the moment you expect to see what the
        // other one did. Waiting up to a minute for a tick is exactly the
        // delay this whole cadence exists to avoid.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let last = self.lastAttemptAt; self.lock.unlock()
            if let last, Date().timeIntervalSince(last) < Cadence.activationThrottle { return }
            self.sync(reason: "app activated")
        }

        sync(reason: "launch")
    }

    private func tick() {
        lock.lock(); let last = lastAttemptAt; lock.unlock()
        guard Cadence.shouldRun(now: Date(), lastAttempt: last,
                                isActive: NSApp?.isActive ?? true) else { return }
        sync(reason: "tick")
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
            self.lock.lock(); self.lastAttemptAt = Date(); self.lock.unlock()

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
        // The fetch first, and NO local snapshot before it.
        //
        // Taking one here was a race with the user: the fetch takes
        // seconds over ssh, and anything typed in that window — a session
        // note, most often — was merged away by a snapshot that predated
        // it. The apply then wrote the old set back over the store and the
        // note vanished, which from the outside looks like "I had to type
        // it three times". Activation triggers a sync, so the worst window
        // is the few seconds after you switch to Onyx: exactly when you
        // sit down and write a note.
        let fetched = fetch(host: host, appState: appState)
        switch fetched {
        case .failure(let message):
            report(.failed(message))
            return
        case .success(let remoteCopy):
            lock.lock(); let base = shadow; lock.unlock()

            // Snapshot, merge, check and apply in ONE main-thread block.
            // Nothing the user does can land in the middle of it.
            let outcome: Outcome = DispatchQueue.main.sync {
                let local = localStateNow()
                let merged: SharedState
                if let remote = remoteCopy {
                    merged = SharedStateMerge.merge(base: base, local: local, remote: remote)
                } else {
                    // NO COPY ON THE HOST. This used to merge against
                    // `.empty`, and with a shadow in hand the merge reads
                    // "present in the shadow, gone from the remote" as a
                    // DELETION — of everything. A missing file is not a
                    // deletion; it is the absence of evidence, reported by
                    // the same transfer that fails when ssh is unhappy.
                    merged = local
                }
                // The backstop, for the failure not yet imagined.
                //
                // Compared against whichever side HAD something: an empty
                // shadow (a first sync, or one just reset by a home-host
                // change) with a populated local would otherwise have let
                // a wipe through the one guard meant to catch it.
                let previous = (base?.isEmpty == false) ? base! : local
                if let refusal = Self.refusal(previous: previous, next: merged) {
                    return Outcome(local: local, merged: merged, refusal: refusal)
                }
                applyNow(merged)
                return Outcome(local: local, merged: merged, refusal: nil)
            }

            if let refusal = outcome.refusal {
                report(.failed(refusal))
                DiagnosticLog.shared.record("config", "shared state REFUSED: \(refusal)",
                                            failure: true)
                return
            }
            if remoteCopy == nil {
                DiagnosticLog.shared.record(
                    "config",
                    "shared state: \(host.label) has no copy — sending ours "
                    + "(\(outcome.merged.notes.count) notes, "
                    + "\(outcome.merged.favorites.count) favorites) "
                    + "rather than treating the absence as a deletion")
            }
            backUpLocally(outcome.local, replacedBy: outcome.merged)

            let merged = outcome.merged
            // Only write when the host's copy would actually change —
            // otherwise two Macs on a timer rewrite the file at each other
            // forever, for nothing.
            if let remote = remoteCopy, merged.sameContent(as: remote) {
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
            let writer = remoteCopy?.writtenBy
            DispatchQueue.main.async {
                self.lastWrittenBy = writer?.isEmpty == false ? writer : nil
                self.status = .synced(stamp)
            }
            DiagnosticLog.shared.record(
                "config",
                "shared state synced with \(host.label) (\(reason)): "
                + "\(merged.notes.count) notes, \(merged.favorites.count) favorites, "
                + "\(merged.githubPipelines.count + merged.gitlabPipelines.count) pipelines")
        }
    }

    /// What one main-thread pass decided.
    private struct Outcome {
        let local: SharedState
        let merged: SharedState
        let refusal: String?
    }

    /// Why a sync result must not be applied, or nil to go ahead.
    ///
    /// One rule, and it is deliberately blunt: a state with zero of
    /// everything cannot follow a state that had something. There is no
    /// legitimate route to it — a user clearing every note, every favorite
    /// and every pipeline in the same four-second window is not a thing
    /// that happens, and if it did, doing it again after seeing this
    /// message costs them one more click. A wipe costs them everything.
    ///
    /// Refusing rather than repairing is the point. The known cause is
    /// fixed above; this catches the one nobody has thought of yet, and
    /// says so in the log instead of leaving the user to notice that their
    /// notes are gone.
    static func refusal(previous: SharedState, next: SharedState) -> String? {
        guard next.isEmpty, !previous.isEmpty else { return nil }
        return "refused to empty \(previous.notes.count) notes, "
            + "\(previous.favorites.count) favorites and "
            + "\(previous.githubPipelines.count + previous.gitlabPipelines.count) pipelines "
            + "in one step — nothing was changed. If this is genuinely what you want, "
            + "clear them on this Mac and they will sync normally."
    }

    /// Caller must already be on main.
    private func localStateNow() -> SharedState {
        SharedState(notes: SessionNotesStore.shared.notes,
                    favorites: FavoritesStore.shared.entries,
                    githubPipelines: GitHubConfigStore.shared.pipelineURLs,
                    gitlabPipelines: GitLabConfigStore.shared.pipelineURLs,
                    prWorkflows: WorkflowFilterStore.shared.includedList,
                    updated: Date(),
                    writtenBy: Self.thisMachine)
    }

    /// Keep a copy of what we are about to replace.
    ///
    /// Written before the stores are touched, and NEVER when the incoming
    /// state is empty — see `moveIntoPlaceScript`. The local copy matters
    /// as much as the host's: it is the one you still have when the host
    /// is the thing that went wrong.
    private func backUpLocally(_ current: SharedState, replacedBy next: SharedState) {
        guard !next.isEmpty, !current.isEmpty, let url = backupURL else { return }
        guard let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: url)
    }

    /// Where the local backup lives — beside the sync record.
    var backupURL: URL? {
        lock.lock(); let u = url; lock.unlock()
        return u?.deletingLastPathComponent()
            .appendingPathComponent("shared-state.backup.json")
    }

    /// Caller must already be on main.
    private func applyNow(_ state: SharedState) {
        applying = true
        SessionNotesStore.shared.replaceAll(state.notes)
        if FavoritesStore.shared.entries != state.favorites {
            FavoritesStore.shared.entries = state.favorites
            FavoritesStore.shared.save()
        }
        // Pipelines: write, then tell the monitor, so a pipeline added
        // on the other Mac starts reporting here without a restart.
        if GitHubConfigStore.shared.pipelineURLs != state.githubPipelines {
            GitHubConfigStore.shared.pipelineURLs = state.githubPipelines
            WorkflowMonitor.shared.refresh()
        }
        if GitLabConfigStore.shared.pipelineURLs != state.gitlabPipelines {
            GitLabConfigStore.shared.pipelineURLs = state.gitlabPipelines
            GitLabPipelineMonitor.shared.refresh()
        }
        // Which workflows PRs show. The filter is applied on read, so
        // the overlay follows without a refresh.
        if WorkflowFilterStore.shared.includedList != state.prWorkflows {
            WorkflowFilterStore.shared.included = Set(state.prWorkflows)
        }
        applying = false
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { self.status = status }
    }

    /// Must hold `lock`.
    private func persist() {
        guard let url else { return }
        // storedHome, not the @Published mirror: this runs on the sync
        // queue, and the mirror belongs to main.
        let record = Record(homeHostID: storedHome, shadow: shadow, lastSync: lastSync)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url)
    }

    static var thisMachine: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: - Transfer

    /// Both scripts go through `runScriptWithFallback`, which retries over a
    /// TTY — so both are bound by the ~1KB payload ceiling and are named
    /// here so `RemoteScriptBudgetTests` can measure them.
    static let makeDirectoryScript =
        "mkdir -p \"\(remoteDirectoryScript)\" && echo READY"

    /// Put the uploaded file in place, keeping the one it replaces.
    ///
    /// `backingUp` is false when the state being written is empty. The
    /// rule is the user's and it is the right one: a backup must never be
    /// overwritten by a copy with nothing in it, because that is exactly
    /// the moment it is needed. Losing the data twice — once in the file,
    /// once in the backup on the next tick — is how a backup becomes
    /// theatre.
    static func moveIntoPlaceScript(backingUp: Bool) -> String {
        var script = "D=\"\(remoteDirectoryScript)\"; F=\"$D/\(remoteFilename)\"\n"
        if backingUp {
            script += "[ -f \"$F\" ] && cp \"$F\" \"$D/\(backupFilename)\"\n"
        }
        return script + "mv \"$F.incoming\" \"$F\" && echo MOVED"
    }

    public static let backupFilename = "shared-state.backup.json"

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
        let (cmd, args) = appState.scpFetchCommand(remotePath: Self.remotePath,
                                                   localPath: local.path, host: host)
        let result = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 30,
                                           captureStdout: true, captureStderr: true,
                                           label: "sharedStatePull:\(host.label)")
        defer { try? FileManager.default.removeItem(at: local) }

        guard let data = try? Data(contentsOf: local) else {
            let verdict = Self.classify(exit: result.exit, stderr: result.stderr)
            switch verdict {
            case .connectionFailure(let why):
                appState.reportSSHFailure(host: host)
                return .failure(why ?? "couldn't reach \(host.label)")
            case .transferFailure(let why):
                return .failure(why)
            case .missing(let complaint):
                _ = complaint
            }
            let complaint = Self.shortError(result.stderr)
            // Nothing at the primary path. Before accepting that, look
            // for the backup: on a genuinely fresh host there isn't one,
            // and where there IS one the primary going missing is the
            // failure this whole commit is about.
            if let rescued = fetchBackup(host: host, appState: appState) {
                DiagnosticLog.shared.record(
                    "config",
                    "shared state: \(host.label) lost its copy — recovered "
                    + "\(rescued.notes.count) notes and \(rescued.favorites.count) "
                    + "favorites from the backup beside it", failure: true)
                return .success(rescued)
            }
            // Nothing there yet — the normal first sync against a host.
            // Logged rather than silent: this branch once swallowed a
            // malformed remote path ("$HOME/…", which scp sends to an
            // SFTP server verbatim) and reported it as an empty host,
            // every cycle, for both directions.
            DiagnosticLog.shared.record(
                "config",
                "shared state: no copy at \(host.label):\(Self.remotePath) yet"
                + (complaint.map { " (\($0))" } ?? ""))
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

    /// Read the host's backup copy, if it has one.
    private func fetchBackup(host: HostConfig, appState: AppState) -> SharedState? {
        let local = scratch.deletingLastPathComponent()
            .appendingPathComponent("onyx-shared-state-backup.json")
        try? FileManager.default.removeItem(at: local)
        let (cmd, args) = appState.scpFetchCommand(remotePath: Self.remoteBackupPath,
                                                   localPath: local.path, host: host)
        _ = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 30,
                                  captureStdout: true, captureStderr: true,
                                  label: "sharedStateBackup:\(host.label)")
        defer { try? FileManager.default.removeItem(at: local) }
        guard let data = try? Data(contentsOf: local),
              let decoded = try? JSONDecoder().decode(SharedState.self, from: data),
              !decoded.isEmpty else { return nil }
        return decoded
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
            Self.makeDirectoryScript, appState: appState, host: host, timeout: 20)
        guard mkdir.cleaned?.contains("READY") == true else {
            report(.failed(mkdir.failureDetail))
            return false
        }

        // Upload beside the real file, then move it into place. scp writes
        // in the clear: an interrupted transfer straight onto the
        // destination leaves a truncated file, and a truncated
        // shared-state.json read by the next Mac is every note gone.
        let (cmd, args) = appState.scpCommand(localPath: local.path,
                                              remotePath: Self.remoteStagingPath, host: host)
        let upload = RemoteExec.shared.run(cmd, args: args, stdin: nil, softTimeout: 30,
                                           captureStdout: true, captureStderr: true,
                                           label: "sharedStatePush:\(host.label)")
        guard upload.exit == 0 else {
            if upload.exit == 255 { appState.reportSSHFailure(host: host) }
            report(.failed(Self.shortError(upload.stderr) ?? "couldn't write to \(host.label)"))
            return false
        }

        let move = FileBrowserManager.runScriptWithFallback(
            Self.moveIntoPlaceScript(backingUp: !state.isEmpty),
            appState: appState, host: host, timeout: 20)
        guard move.cleaned?.contains("MOVED") == true else {
            report(.failed(move.failureDetail))
            return false
        }
        return true
    }

    /// What a failed transfer MEANS.
    ///
    /// Pure, and separated from the I/O, because this is the decision that
    /// wiped a user's data: "the file isn't there" and "I couldn't ask"
    /// look identical from the outside, and treating the second as the
    /// first is what let a flapping connection read as "the remote deleted
    /// everything". It deserves to be testable on its own.
    ///
    /// scp exits 255 for connection problems and 1 for everything else,
    /// so the message is what separates a missing file from a refused one.
    enum FetchVerdict: Equatable {
        /// Couldn't reach the host at all. Skip the cycle.
        case connectionFailure(String?)
        /// Reached it; the transfer was refused for a reason worth showing.
        case transferFailure(String)
        /// Reached it, and there is nothing there — which is NOT evidence
        /// that anything was deleted.
        case missing(String?)
    }

    static func classify(exit: Int32, stderr: String) -> FetchVerdict {
        let complaint = shortError(stderr)
        if exit == 255 { return .connectionFailure(complaint) }
        guard let complaint else { return .missing(nil) }
        let lowered = complaint.lowercased()
        if lowered.contains("no such file") || lowered.contains("not found") {
            return .missing(complaint)
        }
        return .transferFailure(complaint)
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
            return "Notes and favorites are stored on this Mac only."
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
