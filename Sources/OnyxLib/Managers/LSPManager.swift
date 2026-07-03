//
// LSPManager.swift
//
// Responsibility: Owns per-workspace language-server (jdtls) sessions and
//                 answers code-navigation queries for the file browser
//                 (subtypes, implementors, overrides, references, definition).
//                 Resolves a file to its workspace (build root), starts/reuses
//                 one jdtls per workspace, gates on readiness, and maps LSP
//                 results into UI-facing NavResultGroups.
// Scope: Manager. Depends on Services/Models and AppState (for SSH command
//        builders + remote script execution). Never depends on Views.
//
// Concurrency: @MainActor. Because the class is main-actor isolated, every
//        `await` inside its async methods resumes back on the main actor, so
//        the `entries` registry and @Published `state` are touched on one
//        thread without explicit locks. Only LSPSession's internals (its own
//        lock) and the notification callback cross threads — the callback
//        hops back via `Task { @MainActor ... }`.
//
// Workspace model: see docs/lsp-code-navigation-plan.md — "Workspaces vs.
//        favorites". A workspace is the build root (highest build file up to
//        the .git ceiling), NOT a favorite; nested favorites share one session.
//

import Foundation
import Combine

@MainActor
public final class LSPManager: ObservableObject {

    /// Drives the navigation results panel.
    @Published public private(set) var state: CodeNavState = .idle
    /// Whether the results panel should be shown.
    @Published public var panelVisible: Bool = false
    /// Live jdtls import progress (from `$/progress`), shown while indexing.
    @Published public private(set) var indexingDetail: String?

    private let appState: AppState

    /// Default remote/local jdtls launcher. (Per-host config comes in M2.)
    static let defaultJDTLSPath = "~/.onyx/jdtls/bin/jdtls"
    /// Cap on concurrently-running servers; LRU-evicted beyond this.
    static let maxSessions = 4
    /// How long to keep polling a query while jdtls finishes importing.
    static let queryDeadline: TimeInterval = 90
    /// Sessions idle longer than this are shut down (frees the remote JVM).
    static let idleTimeout: TimeInterval = 600
    private var idleTimer: Timer?

    private var entries: [WorkspaceKey: Entry] = [:]
    /// Monotonic token: each navigate() bumps it so a superseded query bails
    /// out at its next async boundary instead of clobbering newer state.
    private var queryToken = 0

    /// The most recent query, kept so "Install language server" can retry it.
    private struct PendingQuery {
        let kind: NavKind, filePath: String, line: Int, character: Int, host: HostConfig
    }
    private var lastQuery: PendingQuery?

    // @MainActor init (the class is @MainActor). AppState constructs this via
    // MainActor.assumeIsolated in its lazy var — `lsp` is only ever first
    // accessed on the main thread.
    public init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Types

    struct WorkspaceKey: Hashable {
        let hostID: UUID
        let root: String
    }

    final class Entry {
        let root: String
        let session: LSPSession
        var ready = false
        var startTask: Task<Bool, Never>?
        var openDocs: Set<String> = []
        var lastUsed = Date()

        init(root: String, session: LSPSession) {
            self.root = root
            self.session = session
        }
    }

    // MARK: - Public API

    /// Run a navigation query for a symbol at (line, character) in `filePath`
    /// on `host`. 1-based `line`, 0-based UTF-16 `character` (matches the
    /// editor's own coordinates once converted by the caller).
    public func navigate(_ kind: NavKind, filePath: String, line: Int, character: Int,
                         host: HostConfig) async {
        queryToken += 1
        let token = queryToken
        lastQuery = PendingQuery(kind: kind, filePath: filePath, line: line,
                                 character: character, host: host)
        panelVisible = true
        indexingDetail = nil
        state = .running(kind)

        // 0. Respect the per-host toggle.
        guard host.codeIntel.enabled else {
            state = .unavailable(reason: "Code intelligence is off for this host.")
            return
        }

        // 1. Resolve the workspace (build root) for this file.
        guard let root = await resolveWorkspaceRoot(filePath: filePath, host: host) else {
            if token == queryToken { state = .unavailable(reason: "No Java project found for this file.") }
            return
        }
        guard token == queryToken, appState.activeHost?.id == host.id else { return }

        // 2. Start or reuse the jdtls session for this workspace.
        state = .indexing(root: (root as NSString).lastPathComponent)
        guard let entry = await session(for: host, root: root) else {
            // Start failed — probe the host to say *why* (and offer install).
            let diagnosed = await diagnose(host: host)
            if token == queryToken { state = diagnosed }
            return
        }
        guard token == queryToken, appState.activeHost?.id == host.id else { return }

        // 3. Ensure the document is open, then run the query (polling while the
        //    project finishes importing — see spike finding #5).
        let uri = Self.fileURI(filePath)
        await ensureOpen(entry: entry, uri: uri, path: filePath, host: host)

        state = .running(kind)
        // Caller passes a 1-based editor line; LSP positions are 0-based.
        let pos: [String: Any] = ["line": max(0, line - 1), "character": character]
        let deadline = Date().addingTimeInterval(Self.queryDeadline)

        while true {
            guard token == queryToken, appState.activeHost?.id == host.id else { return }
            let hits = await runQuery(kind, entry: entry, uri: uri, position: pos)
            if !hits.isEmpty {
                if token == queryToken {
                    indexingDetail = nil
                    let symbol = hits.first(where: { $0.name != nil })?.name
                    state = .results(kind: kind, symbol: symbol, groups: NavResultGroup.group(hits))
                }
                return
            }
            if Date() > deadline { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if token == queryToken { indexingDetail = nil; state = .empty(kind: kind) }
    }

    /// Dismiss the results panel.
    public func closePanel() {
        panelVisible = false
        state = .idle
    }

    /// Install jdtls on the last-queried host, then retry the query. Driven by
    /// the "Install language server" button in the results panel.
    public func installThenRetry() async {
        guard let q = lastQuery else { return }
        state = .installing
        indexingDetail = nil
        let dir = JDTLSBootstrap.installDir(forJDTLSPath:
            q.host.codeIntel.jdtlsPath.isEmpty ? Self.defaultJDTLSPath : q.host.codeIntel.jdtlsPath)
        let ok = await runRemote(JDTLSBootstrap.installScript(installDir: dir),
                                 host: q.host, timeout: 240)
        if let ok, JDTLSBootstrap.installSucceeded(in: ok) {
            await navigate(q.kind, filePath: q.filePath, line: q.line,
                           character: q.character, host: q.host)
        } else {
            state = .setupRequired(reason: "Install failed. Check the host has network access and try again.",
                                   canInstall: true)
        }
    }

    /// Probe a host to explain why the server couldn't start.
    private func diagnose(host: HostConfig) async -> CodeNavState {
        let script = JDTLSBootstrap.preflightScript(jdtlsPath:
            host.codeIntel.jdtlsPath.isEmpty ? Self.defaultJDTLSPath : host.codeIntel.jdtlsPath)
        guard let out = await runRemote(script, host: host, timeout: 12) else {
            return .unavailable(reason: "Couldn't reach the host to check code intelligence.")
        }
        let pf = JDTLSBootstrap.parsePreflight(out)
        if pf.hasJDTLS {
            return .unavailable(reason: "The language server is installed but failed to start.")
        }
        if pf.canInstall {
            return .setupRequired(reason: "The Java language server (jdtls) isn't installed on this host.",
                                  canInstall: true)
        }
        if !pf.javaOK {
            // Surface exactly what the host reported so a mis-detection is
            // self-diagnosing rather than a flat "needs Java" dead end.
            let found: String
            if let major = pf.javaMajor { found = "found Java \(major)" }
            else if let line = pf.javaLine { found = "saw: \(line)" }
            else { found = "no java on the host's PATH / JAVA_HOME" }
            return .setupRequired(reason: "Code intelligence needs Java \(JDTLSBootstrap.minJavaMajor)+ — \(found).",
                                  canInstall: false)
        }
        return .setupRequired(reason: "Installing jdtls needs python3 on the host.", canInstall: false)
    }

    /// Shut down every session (app teardown, or when a host is removed).
    public func shutdownAll() {
        for (_, e) in entries { teardown(e) }
        entries.removeAll()
        idleTimer?.invalidate(); idleTimer = nil
    }

    /// Shut down sessions belonging to a host (call on host removal).
    public func shutdown(hostID: UUID) {
        for (key, e) in entries where key.hostID == hostID {
            teardown(e)
            entries.removeValue(forKey: key)
        }
        if entries.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    // MARK: - Idle eviction

    /// Start the periodic idle sweep once we actually have a session. Skipped
    /// under XCTest (no run loop; mirrors PollLoop's guard).
    private func ensureIdleSweep() {
        guard idleTimer == nil, NSClassFromString("XCTest") == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepIdle() }
        }
    }

    private func sweepIdle() {
        let now = Date()
        for (key, e) in entries where now.timeIntervalSince(e.lastUsed) > Self.idleTimeout {
            teardown(e)
            entries.removeValue(forKey: key)
        }
        if entries.isEmpty { idleTimer?.invalidate(); idleTimer = nil }
    }

    // MARK: - Session lifecycle

    private func session(for host: HostConfig, root: String) async -> Entry? {
        let key = WorkspaceKey(hostID: host.id, root: root)
        if let existing = entries[key], existing.session.isRunning {
            existing.lastUsed = Date()
            return await ensureStarted(existing) ? existing : nil
        }

        // Evict the least-recently-used session if we're at the cap.
        if entries.count >= Self.maxSessions {
            if let lru = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                teardown(lru.value)
                entries.removeValue(forKey: lru.key)
            }
        }

        let dataDir = Self.workspaceDataDir(for: key)
        let jdtls = host.codeIntel.jdtlsPath.isEmpty ? Self.defaultJDTLSPath : host.codeIntel.jdtlsPath
        let heapArg = host.codeIntel.heapMB > 0 ? " --jvm-arg=-Xmx\(host.codeIntel.heapMB)m" : ""
        let launch = "mkdir -p \(dataDir) 2>/dev/null; \(jdtls)\(heapArg) -data \(dataDir)"
        let (cmd, args) = appState.remoteLSPCommand(host: host, launch: launch)
        let entry = Entry(root: root, session: LSPSession(cmd: cmd, args: args))
        entries[key] = entry
        ensureIdleSweep()
        return await ensureStarted(entry) ? entry : nil
    }

    /// Start the server + LSP handshake exactly once per entry, serializing
    /// concurrent callers on `startTask`. Never double-spawns against a locked
    /// `-data` dir (spike finding #6).
    private func ensureStarted(_ entry: Entry) async -> Bool {
        if entry.ready { return true }
        if let task = entry.startTask { return await task.value }
        let task = Task { [weak self] () -> Bool in
            await self?.doStart(entry) ?? false
        }
        entry.startTask = task
        let ok = await task.value
        entry.startTask = nil
        return ok
    }

    private func doStart(_ entry: Entry) async -> Bool {
        entry.session.onNotification = { [weak self, weak entry] method, params in
            switch method {
            case "language/status":
                guard let type = params["type"] as? String,
                      type == "ServiceReady" || type == "Started" else { return }
                Task { @MainActor in entry?.ready = true }
            case "$/progress":
                guard let detail = Self.progressDetail(params) else { return }
                Task { @MainActor in self?.indexingDetail = detail }
            default:
                break
            }
        }
        do { try entry.session.start() } catch { return false }

        let initParams: [String: Any] = [
            "processId": NSNull(),
            "rootUri": Self.fileURI(entry.root),
            "workspaceFolders": [["uri": Self.fileURI(entry.root), "name": "onyx"]],
            "capabilities": [
                "textDocument": [
                    "typeHierarchy": ["dynamicRegistration": true],
                    "callHierarchy": ["dynamicRegistration": true],
                    "implementation": ["dynamicRegistration": true],
                    "references": ["dynamicRegistration": true],
                    "definition": ["dynamicRegistration": true],
                ],
                "window": ["workDoneProgress": true],
            ],
        ]
        let initResult = await entry.session.request("initialize", initParams, timeout: 30)
        guard initResult != nil else { return false }
        entry.session.notify("initialized", [:])
        return true
    }

    private func ensureOpen(entry: Entry, uri: String, path: String, host: HostConfig) async {
        if entry.openDocs.contains(uri) { return }
        guard let text = await fetchContent(path: path, host: host) else { return }
        entry.session.notify("textDocument/didOpen", [
            "textDocument": ["uri": uri, "languageId": "java", "version": 1, "text": text],
        ])
        entry.openDocs.insert(uri)
        // Give jdtls a beat to register the document before the first query.
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private func teardown(_ entry: Entry) {
        Task { await entry.session.request("shutdown", NSNull(), timeout: 3) }
        entry.session.stop()
    }

    // MARK: - Queries

    private func runQuery(_ kind: NavKind, entry: Entry, uri: String,
                          position: [String: Any]) async -> [NavResult] {
        let docPos: [String: Any] = ["textDocument": ["uri": uri], "position": position]

        switch kind {
        case .implementation:
            let r = await entry.session.request("textDocument/implementation", docPos, timeout: 20)
            return Self.results(fromLocations: r)

        case .references:
            var params = docPos
            params["context"] = ["includeDeclaration": true]
            let r = await entry.session.request("textDocument/references", params, timeout: 20)
            return Self.results(fromLocations: r)

        case .definition:
            let r = await entry.session.request("textDocument/definition", docPos, timeout: 20)
            return Self.results(fromLocations: r)

        case .subtypes, .supertypes:
            let prep = await entry.session.request("textDocument/prepareTypeHierarchy", docPos, timeout: 20)
            guard let items = prep as? [[String: Any]], let item = items.first else { return [] }
            let method = kind == .subtypes ? "typeHierarchy/subtypes" : "typeHierarchy/supertypes"
            let r = await entry.session.request(method, ["item": item], timeout: 20)
            return Self.results(fromLocations: r)

        case .callers:
            let prep = await entry.session.request("textDocument/prepareCallHierarchy", docPos, timeout: 20)
            guard let items = prep as? [[String: Any]], let item = items.first else { return [] }
            let r = await entry.session.request("callHierarchy/incomingCalls", ["item": item], timeout: 20)
            // incomingCalls → [{from: CallHierarchyItem, fromRanges: […]}]
            guard let calls = r as? [[String: Any]] else { return [] }
            return calls.compactMap { $0["from"] as? [String: Any] }
                .compactMap(Self.navResult(from:))
        }
    }

    // MARK: - Result mapping

    /// Map an LSP result (array of Location / LocationLink / TypeHierarchyItem,
    /// or a single object) into NavResults.
    static func results(fromLocations raw: Any?) -> [NavResult] {
        let array: [[String: Any]]
        if let a = raw as? [[String: Any]] { array = a }
        else if let o = raw as? [String: Any] { array = [o] }   // definition can be a single object
        else { return [] }
        return array.compactMap(navResult(from:))
    }

    static func navResult(from dict: [String: Any]) -> NavResult? {
        let uri = (dict["uri"] as? String) ?? (dict["targetUri"] as? String)
        guard let uri else { return nil }
        // Prefer selectionRange (the name) over the full range.
        let range = (dict["selectionRange"] as? [String: Any])
            ?? (dict["range"] as? [String: Any])
            ?? (dict["targetSelectionRange"] as? [String: Any])
            ?? (dict["targetRange"] as? [String: Any])
        let start = range?["start"] as? [String: Any]
        let line = ((start?["line"] as? Int) ?? 0) + 1
        let character = (start?["character"] as? Int) ?? 0
        let kindLabel = (dict["kind"] as? Int).flatMap { LSPSymbolKind(rawValue: $0)?.label }
        return NavResult(path: Self.path(fromURI: uri), line: line, character: character,
                         name: dict["name"] as? String,
                         kindLabel: (kindLabel?.isEmpty == false) ? kindLabel : nil)
    }

    /// Build a short human label from an LSP `$/progress` notification's value.
    /// jdtls sends `{value: {kind, title, message, percentage}}` during import.
    static func progressDetail(_ params: [String: Any]) -> String? {
        guard let value = params["value"] as? [String: Any] else { return nil }
        if (value["kind"] as? String) == "end" { return nil }
        let title = value["title"] as? String
        let message = value["message"] as? String
        let text = [title, message].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        guard !text.isEmpty else { return nil }
        if let pct = value["percentage"] as? Int { return "\(text) (\(pct)%)" }
        if let pct = value["percentage"] as? Double { return "\(text) (\(Int(pct))%)" }
        return text
    }

    // MARK: - Workspace resolution (remote walk-up)

    /// Resolve a file to its workspace root on the remote: the HIGHEST build
    /// file up to the .git ceiling; else the git root; else the file's dir.
    /// Runs one noexec-safe remote script (RemoteScript pattern).
    private func resolveWorkspaceRoot(filePath: String, host: HostConfig) async -> String? {
        let dir = (filePath as NSString).deletingLastPathComponent
        let out = await runRemote(Self.workspaceResolveScript(startDir: dir), host: host, timeout: 12)
        let root = out?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !root.isEmpty, root != "/" else { return nil }
        return root
    }

    /// Shell that walks up from `startDir` printing the resolved workspace root.
    static func workspaceResolveScript(startDir: String) -> String {
        let q = shellQuote(startDir)
        return """
        start=\(q)
        # nearest .git ancestor = ceiling (a workspace never spans repos)
        ceil=""; d="$start"
        while [ -n "$d" ]; do
          if [ -e "$d/.git" ]; then ceil="$d"; break; fi
          p=$(dirname "$d"); [ "$p" = "$d" ] && break; d="$p"
        done
        # highest build-file dir at/below the ceiling (aggregator beats module)
        best=""; d="$start"
        while [ -n "$d" ]; do
          if [ -f "$d/pom.xml" ] || [ -f "$d/build.gradle" ] || [ -f "$d/build.gradle.kts" ] || [ -f "$d/settings.gradle" ] || [ -f "$d/settings.gradle.kts" ]; then
            best="$d"
          fi
          if [ -n "$ceil" ] && [ "$d" = "$ceil" ]; then break; fi
          p=$(dirname "$d"); [ "$p" = "$d" ] && break
          if [ -z "$ceil" ] && [ "$p" = "$HOME" ]; then break; fi
          d="$p"
        done
        if [ -n "$best" ]; then echo "$best"
        elif [ -n "$ceil" ]; then echo "$ceil"
        else echo "$start"; fi
        """
    }

    // MARK: - Remote file content (for didOpen)

    private func fetchContent(path: String, host: HostConfig) async -> String? {
        await runRemote("cat -- \(Self.shellQuote(path))", host: host, timeout: 15)
    }

    /// Run a noexec-safe remote script off the main thread, returning cleaned
    /// output (nil on failure / noexec). The one place LSPManager touches the
    /// remote shell for data reads (workspace resolution, file content,
    /// preflight, install).
    private func runRemote(_ script: String, host: HostConfig, timeout: TimeInterval) async -> String? {
        let (cmd, args, stdin) = appState.remoteScript(script, host: host)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: FileBrowserManager.runRemoteScript(
                    cmd: cmd, args: args, stdin: stdin, timeout: timeout))
            }
        }
    }

    // MARK: - URI / path helpers

    static func fileURI(_ path: String) -> String {
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return "file://" + (p.addingPercentEncoding(withAllowedCharacters: allowed) ?? p)
    }

    static func path(fromURI uri: String) -> String {
        var s = uri
        if s.hasPrefix("file://") { s.removeFirst("file://".count) }
        return s.removingPercentEncoding ?? s
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Stable, filesystem-safe `-data` dir name for a workspace.
    static func workspaceDataDir(for key: WorkspaceKey) -> String {
        let scalars = key.root.unicodeScalars
        var sum: UInt32 = 2166136261   // FNV-ish, deterministic across runs
        for u in scalars { sum = (sum ^ u.value) &* 16777619 }
        let slug = key.root.map { $0.isLetter || $0.isNumber ? $0 : "_" }.suffix(40)
        return "~/.onyx/lsp-ws/\(String(slug))_\(String(sum, radix: 36))"
    }
}
