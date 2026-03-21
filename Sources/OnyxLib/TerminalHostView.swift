import SwiftUI
import AppKit
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var appState: AppState

    func makeNSView(context: Context) -> OnyxTerminalView {
        let view = OnyxTerminalView(appState: appState)
        return view
    }

    func updateNSView(_ nsView: OnyxTerminalView, context: Context) {
        if appState.configLoaded && !appState.showSetup && !nsView.hasStarted {
            nsView.startSSH()
        }
        if appState.reconnectRequested {
            DispatchQueue.main.async {
                appState.reconnectRequested = false
                appState.connectionError = nil
                appState.needsKeySetup = false
            }
            nsView.forceReconnect()
        }
        if appState.refreshSessionList {
            DispatchQueue.main.async {
                appState.refreshSessionList = false
            }
            nsView.softRefreshSessions()
        }
        if appState.keySetupInProgress {
            DispatchQueue.main.async {
                appState.keySetupInProgress = false
            }
            nsView.startKeySetup()
        }
        if let session = appState.switchToSession {
            DispatchQueue.main.async {
                appState.switchToSession = nil
            }
            nsView.switchToSession(session)
        }
        if let newSession = appState.createNewSession {
            DispatchQueue.main.async {
                appState.createNewSession = nil
            }
            nsView.createNewTmuxSession(newSession)
        }
        nsView.updateTerminalFont(
            name: appState.appearance.terminalFontName,
            size: appState.appearance.effectiveTerminalFontSize
        )
    }
}

// MARK: - Connection Pool

private struct PoolEntry {
    let terminalView: LocalProcessTerminalView
    var lastActiveTime: Date
    var processRunning: Bool
}

class OnyxTerminalView: NSView {
    let appState: AppState
    var hasStarted = false
    private var reconnectAttempt = 0
    private let maxBackoff: TimeInterval = 15.0
    private var currentFontSize: Double = 13
    private var currentFontName: String = "SF Mono"
    private var lastStartTime: Date?
    private var isKeySetup = false

    // Connection pool: session ID -> pooled terminal view
    private var pool: [String: PoolEntry] = [:]
    private var activeSessionID: String?
    private var evictionTimer: Timer?
    private let evictionTimeout: TimeInterval = 300  // 5 minutes

    /// The currently active terminal view (used by scroll monitor and hitTest)
    private var terminalView: LocalProcessTerminalView? {
        guard let id = activeSessionID else { return nil }
        return pool[id]?.terminalView
    }

    private var focusObserver: Any?
    private var mouseMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = CGColor.clear
        installScrollMonitor()
        startEvictionTimer()
        focusObserver = NotificationCenter.default.addObserver(
            forName: .restoreTerminalFocus, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restoreFocus()
        }
        installFocusMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Don't claim hits when an overlay is covering the terminal
        if appState.showMonitor || appState.showSettings || appState.showCommandPalette
            || appState.showSessionManager || appState.showSetup {
            return nil
        }
        return terminalView?.hitTest(point) ?? super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // Only grab focus if no overlay is covering us
        if !appState.showMonitor && !appState.showSettings && !appState.showCommandPalette
            && !appState.showSessionManager && !appState.showSetup {
            if let tv = terminalView {
                tv.window?.makeFirstResponder(tv)
                appState.focusedComponent = .terminal
            }
        }
        super.mouseDown(with: event)
    }

    /// Monitors all mouseDown events in the window to manage first responder.
    /// Runs SYNCHRONOUSLY during event dispatch so the responder change takes
    /// effect before SwiftUI processes the click on a text field.
    private func installFocusMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self,
                  let window = self.window,
                  event.window === window else { return event }

            let loc = event.locationInWindow
            let myFrame = self.convert(self.bounds, to: nil)

            // Determine if the click landed in the terminal area (and no overlay is blocking it)
            let hasOverlay = self.appState.showMonitor || self.appState.showSettings
                || self.appState.showCommandPalette || self.appState.showSessionManager
                || self.appState.showSetup
            let clickedTerminal = myFrame.contains(loc) && !hasOverlay

            if clickedTerminal {
                self.appState.focusedComponent = .terminal
                // Terminal grabs focus via its own mouseDown, no need to do it here
            } else {
                // Determine which component based on visibility precedence
                if self.appState.showSettings {
                    self.appState.focusedComponent = .settings
                } else if self.appState.showCommandPalette {
                    self.appState.focusedComponent = .commandPalette
                } else if self.appState.showSessionManager {
                    self.appState.focusedComponent = .sessionManager
                } else if self.appState.activeRightPanel != nil {
                    self.appState.focusedComponent = .rightPanel
                } else if self.appState.showMonitor {
                    // Monitor has no text input — terminal keeps focus conceptually
                    self.appState.focusedComponent = .terminal
                }

                // SYNCHRONOUSLY resign terminal first responder BEFORE the click
                // reaches SwiftUI, so the text field under the click can accept focus.
                if let tv = self.terminalView, window.firstResponder === tv {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func restoreFocus() {
        guard let tv = terminalView else { return }
        // Only restore if nothing else should have focus
        guard appState.focusedComponent == .terminal else { return }
        // Use async here because this is called from a notification, and we need
        // the overlay dismissal to finish before we grab focus
        DispatchQueue.main.async {
            guard self.appState.focusedComponent == .terminal else { return }
            tv.window?.makeFirstResponder(tv)
        }
    }

    // MARK: - Pool Management

    /// Activate a session: hide current view, show (or create) the target view
    @discardableResult
    private func activateSession(_ session: TmuxSession, grabFocus: Bool = true) -> LocalProcessTerminalView {
        // Hide the currently active view and stamp its last-active time
        if let currentID = activeSessionID, let entry = pool[currentID] {
            entry.terminalView.isHidden = true
            pool[currentID]?.lastActiveTime = Date()
        }

        // Reuse existing pool entry
        if let entry = pool[session.id] {
            entry.terminalView.isHidden = false
            entry.terminalView.frame = bounds
            activeSessionID = session.id
            hideScroller(on: entry.terminalView)
            if grabFocus {
                DispatchQueue.main.async {
                    entry.terminalView.window?.makeFirstResponder(entry.terminalView)
                }
            }
            return entry.terminalView
        }

        // Create new entry
        let tv = createTerminalView()
        tv.frame = bounds
        addSubview(tv)
        // Hide the scroller after layout creates it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hideScroller(on: tv)
        }
        pool[session.id] = PoolEntry(
            terminalView: tv,
            lastActiveTime: Date(),
            processRunning: false
        )
        activeSessionID = session.id
        if grabFocus {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
        return tv
    }

    private func destroyPoolEntry(_ sessionID: String) {
        guard let entry = pool.removeValue(forKey: sessionID) else { return }
        entry.terminalView.removeFromSuperview()
    }

    private func startEvictionTimer() {
        evictionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.healthCheck()
            self?.evictStaleEntries()
        }
    }

    /// Detect dead processes that didn't trigger processTerminated
    private func healthCheck() {
        guard let id = activeSessionID, let entry = pool[id] else { return }
        guard entry.processRunning else { return }

        // Check if the underlying process is actually still alive
        if !entry.terminalView.process.running {
            print("Health check: active session \(id) process is dead, triggering reconnect")
            pool[id]?.processRunning = false

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.appState.connectionError == nil else { return }
                self.reconnect()
            }
        }
    }

    private func evictStaleEntries() {
        let now = Date()
        let staleIDs = pool.keys.filter { id in
            guard id != activeSessionID else { return false }
            guard let entry = pool[id] else { return false }
            return now.timeIntervalSince(entry.lastActiveTime) > evictionTimeout
        }
        for id in staleIDs {
            destroyPoolEntry(id)
        }
    }

    // MARK: - Scroll Monitor

    private var scrollMonitor: Any?

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let tv = self.terminalView else { return event }
            guard event.deltaY != 0 else { return event }

            guard let window = tv.window,
                  let targetView = window.contentView?.hitTest(event.locationInWindow),
                  targetView === tv || targetView.isDescendant(of: tv) else {
                return event
            }

            guard tv.terminal.mouseMode != .off else {
                return event
            }

            let point = tv.convert(event.locationInWindow, from: nil)
            let cols = CGFloat(tv.terminal.cols)
            let rows = CGFloat(tv.terminal.rows)
            guard cols > 0 && rows > 0 && tv.frame.width > 0 && tv.frame.height > 0 else {
                return event
            }
            let col = max(0, min(Int(point.x / (tv.frame.width / cols)), tv.terminal.cols - 1))
            let row = max(0, min(Int((tv.frame.height - point.y) / (tv.frame.height / rows)), tv.terminal.rows - 1))

            let lines = max(1, Int(abs(event.deltaY)))
            let button = event.deltaY > 0 ? 64 : 65
            for _ in 0..<lines {
                tv.terminal.sendEvent(buttonFlags: button, x: col, y: row)
            }
            return nil
        }
    }

    deinit {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        evictionTimer?.invalidate()
        for id in Array(pool.keys) {
            destroyPoolEntry(id)
        }
    }

    // MARK: - Terminal View Factory

    private func createTerminalView() -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: bounds)
        tv.autoresizingMask = [.width, .height]

        tv.nativeBackgroundColor = NSColor(white: 0.04, alpha: 0.0)
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        tv.wantsLayer = true
        tv.layer?.isOpaque = false
        tv.layer?.backgroundColor = CGColor.clear

        let size = CGFloat(currentFontSize)
        tv.font = resolveFont(name: currentFontName, size: size)

        func c(_ r: Double, _ g: Double, _ b: Double) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }

        let palette: [SwiftTerm.Color] = [
            c(0.04, 0.04, 0.04), c(0.9, 0.3, 0.3), c(0.3, 0.8, 0.4), c(0.9, 0.8, 0.4),
            c(0.4, 0.6, 0.9), c(0.7, 0.4, 0.9), c(0.4, 0.8, 0.9), c(0.85, 0.85, 0.85),
            c(0.3, 0.3, 0.3), c(1.0, 0.4, 0.4), c(0.4, 1.0, 0.5), c(1.0, 0.9, 0.5),
            c(0.5, 0.7, 1.0), c(0.8, 0.5, 1.0), c(0.5, 0.9, 1.0), c(1.0, 1.0, 1.0),
        ]
        tv.installColors(palette)

        tv.processDelegate = self
        return tv
    }

    /// Hide SwiftTerm's built-in scroller on a terminal view
    private func hideScroller(on tv: LocalProcessTerminalView) {
        for subview in tv.subviews {
            if subview is NSScroller {
                subview.isHidden = true
            }
        }
    }

    func updateTerminalFont(name: String, size: Double) {
        guard name != currentFontName || size != currentFontSize else { return }
        currentFontName = name
        currentFontSize = size
        let font = resolveFont(name: name, size: CGFloat(size))
        for entry in pool.values {
            entry.terminalView.font = font
        }
    }

    private func resolveFont(name: String, size: CGFloat) -> NSFont {
        if let font = NSFont(name: name, size: size) {
            return font
        }
        // Fallback chain
        return NSFont(name: "SF Mono", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Connection Lifecycle

    func startSSH() {
        guard !appState.showSetup else { return }
        hasStarted = true
        reconnectAttempt = 0
        lastStartTime = Date()

        DispatchQueue.main.async { self.appState.connectionError = nil }

        enumerateAllSessions {
            self.connectToActiveSession()
        }
    }

    func forceReconnect() {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        // Remember exactly which session we're reconnecting to
        let targetSession = appState.activeSession

        // Destroy only the current session's pool entry for a fresh start
        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }

        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }

        // Re-enumerate to refresh the session list, but always reconnect
        // to the same session — never silently switch to a different one
        enumerateAllSessions {
            DispatchQueue.main.async {
                // Restore the target session regardless of what enumeration found
                if let target = targetSession {
                    self.appState.activeSession = target
                }
                self.connectToActiveSession()
            }
        }
    }

    private func connectToActiveSession(grabFocus: Bool = false) {
        let defaultHost = self.appState.hosts.first ?? .localhost
        let defaultSession = TmuxSession(
            name: defaultHost.ssh.tmuxSession,
            source: .host(hostID: defaultHost.id)
        )
        let session = self.appState.activeSession ?? defaultSession
        let hostLabel = self.appState.host(for: session.source.hostID)?.label ?? "unknown"
        print("connectToActiveSession: \(session.displayLabel) on \(hostLabel) [id: \(session.id)]")

        // Ensure the session appears in allSessions (it may not if enumeration
        // ran before the host was reachable, e.g. right after SSH key setup)
        if !self.appState.allSessions.contains(where: { $0.id == session.id }) {
            self.appState.allSessions.append(session)
        }

        // Clean up stale MCP port listeners before connecting, so -R forwarding succeeds
        if let host = self.appState.host(for: session.source.hostID) {
            self.appState.cleanupRemoteMCPPort(host: host)
        }

        let tv = self.activateSession(session, grabFocus: grabFocus)
        self.lastStartTime = Date()
        let (cmd, args) = self.appState.commandForSession(session)
        tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
        self.pool[session.id]?.processRunning = true
    }

    private enum ProbeResult {
        case ok
        case unreachable
        case keyAuthFailed
    }

    /// Probe a remote host with BatchMode=yes to check connectivity and key auth.
    private func probeHost(_ host: HostConfig) -> ProbeResult {
        guard !host.isLocal else { return .ok }

        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-z", "-w", "3", host.ssh.host, "\(host.ssh.port)"]
        nc.standardOutput = FileHandle.nullDevice
        nc.standardError = FileHandle.nullDevice
        try? nc.run()
        nc.waitUntilExit()
        guard nc.terminationStatus == 0 else { return .unreachable }

        // Try SSH auth up to 2 times — the first attempt on startup may fail
        // transiently (SSH agent not ready, network still initializing, etc.)
        for attempt in 1...2 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var probeArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             "-o", "StrictHostKeyChecking=accept-new"]
            if host.ssh.port != 22 { probeArgs += ["-p", "\(host.ssh.port)"] }
            if !host.ssh.identityFile.isEmpty { probeArgs += ["-i", host.ssh.identityFile] }
            let userHost = host.ssh.user.isEmpty ? host.ssh.host : "\(host.ssh.user)@\(host.ssh.host)"
            probeArgs += [userHost, "true"]
            probe.arguments = probeArgs
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try? probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return .ok }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 1.0) // brief pause before retry
            }
        }
        return .keyAuthFailed
    }

    func startKeySetup() {
        guard let hostID = appState.keySetupHostID,
              let host = appState.host(for: hostID) else { return }

        isKeySetup = true
        reconnectAttempt = 0
        lastStartTime = Date()

        // Use a dedicated non-pooled view for key setup
        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }
        let tv = createTerminalView()
        addSubview(tv)
        // Store temporarily under a synthetic key
        let setupKey = "__key_setup__"
        pool[setupKey] = PoolEntry(terminalView: tv, lastActiveTime: Date(), processRunning: true)
        activeSessionID = setupKey

        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }
        let (cmd, args) = appState.keySetupCommand(host: host)
        tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.window?.makeFirstResponder(tv)
        }
    }

    // MARK: - Session Enumeration

    private func enumerateAllSessions(then completion: @escaping () -> Void) {
        DispatchQueue.main.async { self.appState.isEnumeratingSessions = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let hosts = self.appState.hosts

            let group = DispatchGroup()
            var allResults: [TmuxSession] = []
            let lock = NSLock()

            for host in hosts {
                group.enter()
                self.enumerateHostSessions(host) { sessions in
                    lock.lock()
                    allResults.append(contentsOf: sessions)
                    lock.unlock()
                    group.leave()
                }
            }

            group.wait()

            // Check for missing favorited sessions that can be recreated
            let createdSessions = self.recreateMissingFavorites(existing: allResults, hosts: hosts)
            let finalResults = allResults + createdSessions

            DispatchQueue.main.async {
                if finalResults.isEmpty {
                    let defaultHost = self.appState.hosts.first ?? .localhost
                    let fallback = TmuxSession(
                        name: defaultHost.ssh.tmuxSession,
                        source: .host(hostID: defaultHost.id)
                    )
                    self.appState.allSessions = [fallback]
                    if self.appState.activeSession == nil {
                        self.appState.activeSession = fallback
                    }
                } else {
                    self.appState.allSessions = finalResults
                    // Only reassign active session if there is none at all.
                    // Never silently switch to a different session — that causes
                    // cross-host/cross-container session confusion.
                    if self.appState.activeSession == nil {
                        let defaultHost = self.appState.hosts.first ?? .localhost
                        let defaultMatch = finalResults.first {
                            $0.source.hostID == defaultHost.id
                                && $0.name == defaultHost.ssh.tmuxSession
                                && !$0.source.isDocker
                        }
                        self.appState.activeSession = defaultMatch ?? finalResults.first
                    }
                }
                self.appState.isEnumeratingSessions = false
                completion()
            }
        }
    }

    /// Recreate favorited tmux sessions that no longer exist on reachable hosts.
    /// Only creates sessions when we're confident the host is reachable and tmux
    /// simply doesn't have that session — never on probe failure or SSH errors.
    private func recreateMissingFavorites(existing: [TmuxSession], hosts: [HostConfig]) -> [TmuxSession] {
        let existingIDs = Set(existing.map(\.id))
        let favoriteIDs = appState.favoritedSessionIDs
        let reachableHostIDs = Set(existing.map(\.source.hostID))

        // Running docker container names per host (from existing enumeration)
        var runningContainers: [UUID: Set<String>] = [:]
        for session in existing {
            if let container = session.source.containerName {
                runningContainers[session.source.hostID, default: []].insert(container)
            }
        }

        var created: [TmuxSession] = []

        for favID in favoriteIDs {
            guard !existingIDs.contains(favID) else { continue }
            guard let session = appState.parseFavoriteID(favID) else { continue }

            let hostID = session.source.hostID
            guard let host = hosts.first(where: { $0.id == hostID }) else { continue }

            // Only recreate if we know the host is reachable (it returned sessions or is local)
            guard host.isLocal || reachableHostIDs.contains(hostID) else { continue }

            let safeName = appState.sanitizedSession(session.name)
            let script: String

            switch session.source {
            case .host:
                // Create a detached tmux session on the host
                script = "tmux new-session -d -s \(safeName) 2>/dev/null && echo CREATED || echo EXISTS"
            case .docker(_, let container):
                // Only if the container is currently running
                guard runningContainers[hostID]?.contains(container) == true else { continue }
                let safeContainer = appState.sanitizedContainer(container)
                script = "docker exec \(safeContainer) tmux new-session -d -s \(safeName) 2>/dev/null && echo CREATED || echo EXISTS"
            default:
                continue
            }

            let (cmd, args) = appState.remoteCommand(script, host: host)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }

            // Only add to results if the command succeeded (exit 0)
            guard process.terminationStatus == 0 else { continue }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard output.contains("CREATED") || output.contains("EXISTS") else { continue }

            print("recreateMissingFavorites: recreated \(session.displayLabel)")
            created.append(session)
        }

        return created
    }

    private func enumerateHostSessions(_ host: HostConfig, completion: @escaping ([TmuxSession]) -> Void) {
        // For remote hosts, probe first
        if !host.isLocal {
            let result = probeHost(host)
            if result == .keyAuthFailed {
                let hostID = host.id
                let label = host.label
                DispatchQueue.main.async {
                    // Guard against race: host may have been removed while probe was running
                    guard self.appState.hosts.contains(where: { $0.id == hostID }) else { return }
                    self.appState.needsKeySetup = true
                    self.appState.keySetupHostID = hostID
                    self.appState.connectionError = "Key authentication failed for \(label).\nInstall your SSH key to connect."
                }
                completion([])
                return
            } else if result == .unreachable {
                completion([])
                return
            }
        }

        let group = DispatchGroup()
        var hostSessions: [TmuxSession] = []
        var dockerSessions: [TmuxSession] = []
        let lock = NSLock()

        group.enter()
        fetchTmuxSessions(host: host, source: .host(hostID: host.id)) { sessions in
            lock.lock()
            hostSessions = sessions
            lock.unlock()
            group.leave()
        }

        group.enter()
        fetchDockerContainerSessions(host: host) { sessions in
            lock.lock()
            dockerSessions = sessions
            lock.unlock()
            group.leave()
        }

        group.wait()
        completion(hostSessions + dockerSessions)
    }

    private func fetchTmuxSessions(host: HostConfig, source: SessionSource, completion: @escaping ([TmuxSession]) -> Void) {
        let script: String
        switch source {
        case .host:
            script = "tmux ls -F \"#{session_name}\" 2>/dev/null || true"
        case .docker(_, let containerName):
            let safe = appState.sanitizedContainer(containerName)
            script = "docker exec \(safe) tmux ls -F \"#{session_name}\" 2>/dev/null || true"
        case .dockerLogs, .dockerTop:
            completion([]) // utility sessions are not fetched via tmux
            return
        }

        let (cmd, args) = appState.remoteCommand(script, host: host)

        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion([])
            return
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let sessions = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == " " } && !line.contains("  ") && line.count < 100 }
            .map { TmuxSession(name: $0, source: source) }

        completion(sessions)
    }

    private func fetchDockerContainerSessions(host: HostConfig, completion: @escaping ([TmuxSession]) -> Void) {
        let listScript = "docker ps --format \"{{.Names}}\" 2>/dev/null || true"
        let (cmd, args) = appState.remoteCommand(listScript, host: host)

        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            completion([])
            return
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let containerNames = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !containerNames.isEmpty else {
            completion([])
            return
        }

        var allDockerSessions: [TmuxSession] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for containerName in containerNames {
            group.enter()

            let source = SessionSource.docker(hostID: host.id, containerName: containerName)
            fetchTmuxSessions(host: host, source: source) { sessions in
                lock.lock()
                // Always add utility sessions for each container
                allDockerSessions.append(TmuxSession(
                    name: "logs",
                    source: .dockerLogs(hostID: host.id, containerName: containerName)
                ))
                allDockerSessions.append(TmuxSession(
                    name: "top",
                    source: .dockerTop(hostID: host.id, containerName: containerName)
                ))
                if !sessions.isEmpty {
                    allDockerSessions.append(contentsOf: sessions)
                }
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        completion(allDockerSessions)
    }

    // MARK: - Session Switching

    func switchToSession(_ session: TmuxSession) {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        DispatchQueue.main.async {
            self.appState.activeSession = session
            self.appState.connectionError = nil
        }

        // If the pooled view already has a running process, instant switch
        if let entry = pool[session.id], entry.processRunning {
            activateSession(session)
            return
        }

        // Dead or missing session — destroy stale entry so we get a fresh terminal
        destroyPoolEntry(session.id)
        let tv = activateSession(session)

        let (cmd, args) = appState.commandForSession(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
            self.pool[session.id]?.processRunning = true
        }
    }

    func createNewTmuxSession(_ session: TmuxSession) {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        DispatchQueue.main.async {
            self.appState.allSessions.append(session)
            self.appState.activeSession = session
            self.appState.connectionError = nil
        }

        let tv = activateSession(session)
        let (cmd, args) = appState.commandForSession(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
            self.pool[session.id]?.processRunning = true
        }
    }

    /// Light refresh: re-enumerate sessions without disrupting the current connection.
    /// Used after settings changes to detect new hosts and trigger key setup if needed.
    func softRefreshSessions() {
        enumerateAllSessions {}
    }

    /// Manual refresh: tear down and reconnect the active session
    func refreshActiveSession() {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        let targetSession = appState.activeSession

        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }

        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.isReconnecting = false
        }

        enumerateAllSessions {
            DispatchQueue.main.async {
                if let target = targetSession {
                    self.appState.activeSession = target
                }
                // Only grab focus if the terminal still has it — the user may
                // have switched to another panel while waiting for the reconnect
                let shouldFocus = self.appState.focusedComponent == .terminal
                self.connectToActiveSession(grabFocus: shouldFocus)
            }
        }
    }

    private func reconnect() {
        let targetSession = appState.activeSession
        let delay = min(pow(2.0, Double(reconnectAttempt)) * 0.5, maxBackoff)
        reconnectAttempt += 1

        DispatchQueue.main.async {
            self.appState.isReconnecting = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.appState.isReconnecting = false
            self.lastStartTime = Date()

            // Destroy the dead entry so we get a fresh terminal view
            if let id = self.activeSessionID {
                self.destroyPoolEntry(id)
                self.activeSessionID = nil
            }

            // Restore the target session — don't let enumeration reassign it
            self.enumerateAllSessions {
                DispatchQueue.main.async {
                    if let target = targetSession {
                        self.appState.activeSession = target
                    }
                    self.connectToActiveSession()
                }
            }
        }
    }
}

// MARK: - Terminal Delegate

extension OnyxTerminalView: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            source.window?.title = title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let wasKeySetup = isKeySetup
        isKeySetup = false

        // Find which pool entry this view belongs to
        let terminatedSessionID = pool.first(where: { $0.value.terminalView === source })?.key

        if let id = terminatedSessionID {
            pool[id]?.processRunning = false
        }

        print("processTerminated: session=\(terminatedSessionID ?? "unknown") active=\(activeSessionID ?? "none") exit=\(exitCode.map(String.init) ?? "nil")")

        if wasKeySetup {
            if exitCode != 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.appState.connectionError = "SSH key setup failed. Use ⌘K → Reconnect to try again."
                    self?.appState.isReconnecting = false
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let id = self.activeSessionID {
                        self.destroyPoolEntry(id)
                        self.activeSessionID = nil
                    }
                    self.reconnectAttempt = 0
                    self.enumerateAllSessions {
                        self.connectToActiveSession()
                        // Re-enumerate after a delay to pick up the tmux session
                        // that connectToActiveSession just created on the new host
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            self?.softRefreshSessions()
                        }
                    }
                }
            }
            return
        }

        // If we couldn't find which session this was, but the active session's
        // process is also dead, treat it as the active session dying
        let isActiveSession: Bool
        if let id = terminatedSessionID {
            isActiveSession = (id == activeSessionID)
        } else if let activeID = activeSessionID,
                  let entry = pool[activeID],
                  !entry.terminalView.process.running {
            // Pool lookup failed but active session process is dead
            pool[activeID]?.processRunning = false
            isActiveSession = true
        } else {
            isActiveSession = false
        }

        guard isActiveSession else {
            // Background session died — destroy its pool entry so next switch gets a fresh view
            if let id = terminatedSessionID {
                destroyPoolEntry(id)
            }
            return
        }

        // Active session died — auto-reconnect (except read-only log streams)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.appState.connectionError != nil {
                self.appState.isReconnecting = false
                return
            }
            // Don't auto-reconnect docker logs — the container may have stopped
            if let session = self.appState.activeSession, session.source.isDockerLogs {
                return
            }
            self.reconnect()
        }
    }
}
