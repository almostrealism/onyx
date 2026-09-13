//
// AppState+Persistence.swift
//
// Responsibility: Where Onyx keeps things on disk and how they are loaded
//                 — the file URLs under Application Support, the stores
//                 that read them at launch, and the one-way migrations
//                 that move stored entries when a keying scheme changes.
// Scope: An extension on AppState.
//
// Split out of AppState.swift, which had grown past the point where the
// file could be read as one thing. Nothing here changed in the move.
//
// The migrations are the part to read carefully. `migrateStorageKeysIfNeeded`
// rewrites keys people's notes and favorites are filed under, and the
// rule learned the hard way is that the READER must accept both forms
// before anything on disk is touched — see the commit that wiped a
// favorites list, and StorageKeyResolutionTests, which exists so it
// can't happen twice.
//

import Foundation
import AppKit
import SwiftUI

extension AppState {
    // MARK: - Persistence

    private var appSupportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Onyx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var hostsURL: URL {
        appSupportDir.appendingPathComponent("hosts.json")
    }

    private var legacyConfigURL: URL {
        appSupportDir.appendingPathComponent("config.json")
    }

    private var appearanceURL: URL {
        appSupportDir.appendingPathComponent("appearance.json")
    }

    private var favoritesURL: URL {
        appSupportDir.appendingPathComponent("favorites.json")
    }

    private var sessionNotesURL: URL {
        appSupportDir.appendingPathComponent("session-notes.json")
    }

    private var alertsURL: URL {
        appSupportDir.appendingPathComponent("alerts.json")
    }

    /// Where the home host and the shadow of the last sync are kept. Not
    /// the shared state itself — that IS favorites.json and
    /// session-notes.json, which stay the working copy.
    private var sharedStateURL: URL {
        appSupportDir.appendingPathComponent("shared-sync.json")
    }

    private var pageWatchesURL: URL {
        appSupportDir.appendingPathComponent("page-watches.json")
    }

    /// Path the screensaver reads. Lives under /Users/Shared/ rather than
    /// ~/Library/Application Support/ because legacyScreenSaver is sandboxed
    /// and can't read paths inside the user's Library. /Users/Shared is
    /// world-readable on every Mac and accessible regardless of sandbox.
    /// See OnyxScreenSaver/.
    private var cpuStreamURL: URL {
        URL(fileURLWithPath: "/Users/Shared/Onyx/cpu-stream.json")
    }

    private var sessionsURL: URL {
        appSupportDir.appendingPathComponent("sessions.json")
    }

    private var topologyURL: URL {
        appSupportDir.appendingPathComponent("topology.json")
    }

    /// Notes directory.
    public var notesDirectory: URL {
        let dir = appSupportDir.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Jump to file search (Cmd+Shift+F). Opens the file browser in search
    /// mode at the "search home" (the last-opened favorite). If text is
    /// selected in the file viewer, run a search for it immediately;
    /// otherwise just focus the field so the user can type.
    public func beginFileSearch() {
        let browser = fileBrowserManager
        let selection = browser.currentSelection.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dispose any open file so the search results are immediately visible.
        // The browser renders the file view on top of search, so leaving a file
        // open traps the user — they'd have to hit Back repeatedly to reach the
        // results. (selection was captured above, before closeFile clears it.)
        browser.closeFile()

        if !showFullFileBrowser { activeRightPanel = .fileBrowser }

        // Land on the search home so the user searches the project root they
        // expect (navigateTo clears any prior search first).
        if let home = browser.searchHomePath, browser.currentPath != home {
            browser.navigateTo(home)
        }

        if !selection.isEmpty {
            browser.searchQuery = selection
            browser.startSearch(selection)
        } else {
            browser.isSearchActive = true
            browser.requestSearchFocus()
        }
    }

    /// Open a recognized file path (from the terminal-text overlay) in the
    /// file browser. `selectFile` opens the file itself; otherwise we land
    /// in its containing directory (the shift-click behavior).
    public func openPathInFileBrowser(_ path: String, selectFile: Bool) {
        showTerminalText = false
        terminalTextContent = ""
        activeRightPanel = .fileBrowser
        if selectFile {
            let name = (path as NSString).lastPathComponent
            // readFileFromSearch moves currentPath to the file's folder and
            // opens the file — exactly "browser with that file selected".
            fileBrowserManager.readFileFromSearch(path, name: name)
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            fileBrowserManager.navigateTo(parent)
        }
    }

    /// Saved folders url.
    public var savedFoldersURL: URL {
        appSupportDir.appendingPathComponent("folders.json")
    }

    /// Accent color.
    public var accentColor: Color {
        let hex = appearance.windowAccents[windowIndex] ?? appearance.accentHex
        return Color(hex: hex)
    }

    /// The effective accent hex for this window
    public var effectiveAccentHex: String {
        appearance.windowAccents[windowIndex] ?? appearance.accentHex
    }

    /// Scale factor for UI text relative to default size of 12
    public var uiScale: CGFloat {
        CGFloat(appearance.uiFontSize / 12.0)
    }

    /// Scaled UI font size — multiply a base size by the UI scale factor
    public func uiSize(_ base: CGFloat) -> CGFloat {
        (base * uiScale).rounded()
    }

    /// Load config.
    public func loadConfig() {
        // Try loading multi-host config
        if FileManager.default.fileExists(atPath: hostsURL.path) {
            if let data = try? Data(contentsOf: hostsURL),
               let loaded = try? JSONDecoder().decode([HostConfig].self, from: data) {
                hosts = loaded
            }
        } else if FileManager.default.fileExists(atPath: legacyConfigURL.path) {
            // Migrate from single-host config
            if let data = try? Data(contentsOf: legacyConfigURL),
               let sshConfig = try? JSONDecoder().decode(SSHConfig.self, from: data) {
                let label = sshConfig.host.isEmpty ? "localhost" : sshConfig.host
                let migrated = HostConfig(id: UUID(), label: label, ssh: sshConfig)
                hosts = [migrated]
            }
        }

        // Ensure localhost is always present
        if !hosts.contains(where: { $0.id == HostConfig.localhostID }) {
            hosts.insert(.localhost, at: 0)
        }

        // If we only have localhost, show setup to add a remote host
        if hosts.count <= 1 && !FileManager.default.fileExists(atPath: hostsURL.path) && !FileManager.default.fileExists(atPath: legacyConfigURL.path) {
            showSetup = true
        }

        saveHosts()

        AppearanceStore.shared.configure(url: appearanceURL)

        loadFavorites()
        migrateStorageKeysIfNeeded()
        loadTopology()
        loadLocalSessions()
        configLoaded = true

        startupStatus = "Loading configuration..."

        // Start background monitoring immediately
        startupStatus = "Starting monitors..."
        monitor.startPolling()
        TimingDataStore.shared.startPolling()
        _ = timing // trigger lazy init so it subscribes to store changes

        // Start MCP socket server for agent integration
        mcpServer = MCPSocketServer(artifactManager: artifactManager, claudeSessions: claudeSessions)
        mcpServer?.start()

        // Start dashboard HTTP server for browser new-tab monitoring
        dashboardServer = DashboardServer(appState: self)
        dashboardServer?.start()
    }

    /// Save hosts.
    public func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: hostsURL)
        }
    }

    /// Legacy compat: called by SetupView after first host is configured
    public func saveConfig() {
        saveHosts()
        showSetup = false
    }

    /// Save appearance.
    public func saveAppearance() {
        AppearanceStore.shared.save()
    }

    /// Persist which session this window is using
    public func saveLastSession() {
        guard let session = activeSession else { return }
        appearance.lastSessionByWindow[windowIndex] = session.id
        saveAppearance()
    }

    /// Get the session ID that should be restored for this window
    public var restoredSessionID: String? {
        appearance.lastSessionByWindow[windowIndex]
    }

    /// STEP 2: rewrite stored keys to the identity form.
    ///
    /// Safe only because step 1 landed first — every read already accepts
    /// both forms, so a file that is un-migrated, migrated, or caught
    /// half-way all resolve identically. That ordering is the whole
    /// lesson from the attempt that wiped a favorites list.
    ///
    /// Idempotent: an already-migrated key has "@" in its machine field
    /// and is skipped, so this runs on every launch and does nothing
    /// after the first.
    ///
    /// A key naming a host that no longer exists is LEFT ALONE. Someone
    /// may re-add that host, and dropping notes in a migration would be
    /// unforgivable — step 1 means those keep resolving anyway.
    ///
    /// Both files are copied aside once before anything is touched.
    func migrateStorageKeysIfNeeded() {
        var mapping: [String: String] = [:]
        // Build from LIVE sessions: each one knows both of its keys, so
        // the mapping is derived from the same resolver the reader uses
        // rather than from a second parse of the stored string.
        for session in allSessions {
            let keys = storageKeys(for: session)
            guard keys.count == 2 else { continue }   // no host → nothing to move
            mapping[keys[1]] = keys[0]                // legacy → identity
        }
        // Sessions that aren't currently listed still have stored entries;
        // reconstruct those from the host list.
        for host in hosts {
            let prefix = "host:\(host.id.uuidString):"
            let machine = SessionIdentity.key(for: host)
            for key in SessionNotesStore.shared.notes.keys
                        + FavoritesStore.shared.entries.map(\.sessionID)
            where key.hasPrefix(prefix) && mapping[key] == nil {
                mapping[key] = "host:\(machine):" + key.dropFirst(prefix.count)
            }
        }

        let stored = Set(SessionNotesStore.shared.notes.keys)
            .union(FavoritesStore.shared.entries.map(\.sessionID))
        mapping = mapping.filter { stored.contains($0.key) }
        guard !mapping.isEmpty else { return }

        for url in [sessionNotesURL, favoritesURL] {
            let backup = url.appendingPathExtension("pre-rekey")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
        }

        SessionNotesStore.shared.rekey(mapping)
        var entries = favoriteEntries
        for i in entries.indices {
            if let new = mapping[entries[i].sessionID] { entries[i].sessionID = new }
        }
        favoriteEntries = entries
        saveFavorites()
        // Renaming in place can land two entries on the same key — a
        // session favorited before the re-keying and touched after it has
        // one of each. The notes store has always merged on collision;
        // this didn't, and the result was every affected favorite drawn
        // twice in the bar.
        collapseDuplicateFavorites()

        DiagnosticLog.shared.record(
            "config", "session keys moved to user@host (\(mapping.count) entries)")
    }

    /// One entry per session, whatever the file says.
    ///
    /// Two entries can name the same session while spelling it
    /// differently — the legacy in-memory id and the identity key — and a
    /// favorite stored twice is drawn twice in the bar and answers to two
    /// ⌘-numbers. Entries are collapsed onto the identity key, keeping the
    /// FIRST position (the user arranged that) and the union of the
    /// windows (so a favorite visible in two windows stays visible in
    /// both).
    ///
    /// Entries that resolve to no live session are left exactly as they
    /// are: a host that's merely switched off must not have its
    /// favorites rewritten or dropped.
    ///
    /// Runs at load as a repair, not just after the migration, because the
    /// duplicates are already in people's files.
    func collapseDuplicateFavorites() {
        var positions: [String: Int] = [:]
        var collapsed: [FavoriteEntry] = []
        var changed = false
        let map = sessionsByStorageKey(allSessions)

        for entry in favoriteEntries {
            // The canonical spelling, when we can work one out.
            let key = map[entry.sessionID].map { storageKey(for: $0) } ?? entry.sessionID
            if let index = positions[key] {
                collapsed[index].windows.formUnion(entry.windows)
                changed = true
                continue
            }
            positions[key] = collapsed.count
            var normalized = entry
            if normalized.sessionID != key {
                normalized.sessionID = key
                changed = true
            }
            collapsed.append(normalized)
        }

        guard changed else { return }
        favoriteEntries = collapsed
        saveFavorites()
        DiagnosticLog.shared.record("config", "favorites collapsed to one entry per session")
    }

    func loadFavorites() {
        FavoritesStore.shared.configure(url: favoritesURL)
        SessionNotesStore.shared.configure(url: sessionNotesURL)
        AlertStore.shared.configure(url: alertsURL)
        // Alerts attach to sessions, not to windows, so the delivery path
        // binds once to whichever window came up first.
        AlertDelivery.shared.register(appState: self)
        // Same rationale for the menu bar item, which shows the same
        // alerts against the same sessions. Never under XCTest: a test
        // process has no business putting an icon in the user's menu bar.
        if NSClassFromString("XCTest") == nil {
            MenuBarController.shared.register(appState: self)
            MenuBarController.shared.setEnabled(appearance.showMenuBarItem)
            // Shared state. Configured AFTER both stores are loaded, so
            // the first sync merges against real local content rather than
            // an empty set — merging an empty local copy into the host's
            // would look exactly like "this Mac deleted everything".
            SharedStateSync.shared.configure(url: sharedStateURL, appState: self)
        }
        // Wire up the screensaver pipeline. Both calls are no-ops under
        // XCTest so unit tests don't write to the user's real cpu-stream.json
        // or kick off real SSH fan-out polling.
        if NSClassFromString("XCTest") == nil {
            CPUStreamStore.shared.configure(url: cpuStreamURL)
            CPUFleetPoller.shared.start(appState: self)
            // Page watches. Cheap when none are configured (the tick just
            // finds nothing due) and the store is loaded either way so the
            // settings list survives a restart.
            AlertDelivery.shared.requestExternalPermissionIfPossible()
            PageWatchStore.shared.configure(url: pageWatchesURL)
            PageWatchManager.shared.start()
            // Start polling configured GitHub repos for open PRs. The
            // manager guards itself against an empty config and is a
            // no-op under XCTest.
            PullRequestManager.shared.startPolling()
            // GitHub Actions pipeline monitor — same poll/config pattern
            // as the PR manager, polls the user's configured pipelines.
            WorkflowMonitor.shared.startPolling()
            // GitLab counterparts — merge requests + explicit pipelines.
            // Same self-guarding/no-op-under-XCTest pattern; their output
            // is merged with GitHub's in the monitor overlay.
            GitLabMergeRequestManager.shared.startPolling()
            GitLabPipelineMonitor.shared.startPolling()
            // SSH connection supervisor — maintains the two-connection
            // pair (active + standby) per host so a single connection
            // failure is instantly recoverable via promotion.
            ConnectionPairRegistry.shared.start(appState: self)
        }
    }

    func loadTopology() {
        NetworkTopologyStore.shared.configure(url: topologyURL)
        NetworkTopologyStore.shared.gc()
    }

    func saveFavorites() {
        FavoritesStore.shared.save()
    }

    /// Save local sessions (browser, etc.) so they survive app restarts.
    public func saveLocalSessions() {
        let entries = allSessions
            .filter { $0.source.isLocal }
            .map { PersistedSession(name: $0.name, sourceStableKey: $0.source.stableKey) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: sessionsURL)
        }
    }

    /// Load persisted local sessions and add them to allSessions.
    func loadLocalSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let entries = try? JSONDecoder().decode([PersistedSession].self, from: data) else { return }
        for entry in entries {
            // Parse the stableKey back into a source
            guard entry.sourceStableKey.hasPrefix("browser:") else { continue }
            let url = String(entry.sourceStableKey.dropFirst("browser:".count))
            guard !url.isEmpty else { continue }
            let session = TmuxSession(name: entry.name, source: .browser(url: url))
            // Avoid duplicates
            if !allSessions.contains(where: { $0.id == session.id }) {
                allSessions.append(session)
            }
        }
    }
}
