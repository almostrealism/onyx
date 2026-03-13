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
        nsView.updateFontSize(appState.appearance.fontSize)
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

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = CGColor.clear
        installScrollMonitor()
        startEvictionTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return terminalView?.hitTest(point) ?? super.hitTest(point)
    }

    // MARK: - Pool Management

    /// Activate a session: hide current view, show (or create) the target view
    @discardableResult
    private func activateSession(_ session: TmuxSession) -> LocalProcessTerminalView {
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
            DispatchQueue.main.async {
                entry.terminalView.window?.makeFirstResponder(entry.terminalView)
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
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
        }
        return tv
    }

    private func destroyPoolEntry(_ sessionID: String) {
        guard let entry = pool.removeValue(forKey: sessionID) else { return }
        entry.terminalView.removeFromSuperview()
    }

    private func startEvictionTimer() {
        evictionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evictStaleEntries()
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
        if let sfMono = NSFont(name: "SF Mono", size: size) {
            tv.font = sfMono
        } else {
            tv.font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

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

    func updateFontSize(_ newSize: Double) {
        guard newSize != currentFontSize else { return }
        currentFontSize = newSize
        let size = CGFloat(newSize)
        let font: NSFont
        if let sfMono = NSFont(name: "SF Mono", size: size) {
            font = sfMono
        } else {
            font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        for entry in pool.values {
            entry.terminalView.font = font
        }
    }

    // MARK: - Connection Lifecycle

    func startSSH() {
        guard !appState.showSetup else { return }
        hasStarted = true
        reconnectAttempt = 0
        lastStartTime = Date()

        DispatchQueue.main.async { self.appState.connectionError = nil }

        if !appState.isLocal {
            probeAndConnect()
        } else {
            enumerateAllSessions {
                self.connectToActiveSession()
            }
        }
    }

    func forceReconnect() {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        // Destroy only the current session's pool entry for a fresh start
        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }

        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }

        if !appState.isLocal {
            probeAndConnect()
        } else {
            enumerateAllSessions {
                self.connectToActiveSession()
            }
        }
    }

    private func connectToActiveSession() {
        DispatchQueue.main.async {
            let session = self.appState.activeSession ?? TmuxSession(name: self.appState.sshConfig.tmuxSession, source: .host)
            let tv = self.activateSession(session)
            self.lastStartTime = Date()
            let (cmd, args) = self.appState.commandForSession(session)
            tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
            self.pool[session.id]?.processRunning = true
        }
    }

    /// Probe SSH with BatchMode=yes. If key auth works, connect normally.
    private func probeAndConnect() {
        let host = appState.sshConfig.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = appState.sshConfig.port
        let user = appState.sshConfig.user
        let identityFile = appState.sshConfig.identityFile

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let nc = Process()
            nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            nc.arguments = ["-z", "-w", "3", host, "\(port)"]
            nc.standardOutput = FileHandle.nullDevice
            nc.standardError = FileHandle.nullDevice
            try? nc.run()
            nc.waitUntilExit()

            guard nc.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self.appState.needsKeySetup = false
                    self.appState.connectionError = """
                    Connection refused on \(host):\(port).

                    SSH (Remote Login) may not be enabled.

                    To enable it:
                    System Settings → General → Sharing → Remote Login → turn ON

                    Then use ⌘K → Reconnect SSH.
                    """
                }
                return
            }

            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            var probeArgs = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             "-o", "StrictHostKeyChecking=accept-new"]
            if port != 22 { probeArgs += ["-p", "\(port)"] }
            if !identityFile.isEmpty { probeArgs += ["-i", identityFile] }
            let userHost = user.isEmpty ? host : "\(user)@\(host)"
            probeArgs += [userHost, "true"]
            probe.arguments = probeArgs
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try? probe.run()
            probe.waitUntilExit()

            if probe.terminationStatus == 0 {
                self.enumerateAllSessions {
                    self.connectToActiveSession()
                }
            } else {
                DispatchQueue.main.async {
                    self.appState.needsKeySetup = true
                    self.appState.connectionError = """
                    SSH key authentication failed for \(host).

                    Your SSH key needs to be installed on the remote host.
                    Onyx can do this for you — you'll enter your password once.
                    """
                }
            }
        }
    }

    func startKeySetup() {
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
        let (cmd, args) = appState.keySetupCommand()
        tv.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
    }

    // MARK: - Session Enumeration

    private func enumerateAllSessions(then completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let group = DispatchGroup()
            var hostSessions: [TmuxSession] = []
            var dockerSessions: [TmuxSession] = []

            group.enter()
            self.fetchTmuxSessions(source: .host) { sessions in
                hostSessions = sessions
                group.leave()
            }

            group.enter()
            self.fetchDockerContainerSessions { sessions in
                dockerSessions = sessions
                group.leave()
            }

            group.wait()

            let allSessions = hostSessions + dockerSessions

            DispatchQueue.main.async {
                let defaultSession = self.appState.sshConfig.tmuxSession
                if allSessions.isEmpty {
                    let fallback = TmuxSession(name: defaultSession, source: .host)
                    self.appState.allSessions = [fallback]
                    self.appState.activeSession = fallback
                } else {
                    self.appState.allSessions = allSessions
                    if let current = self.appState.activeSession,
                       allSessions.contains(where: { $0.id == current.id }) {
                        // still valid
                    } else {
                        let defaultMatch = allSessions.first { $0.source == .host && $0.name == defaultSession }
                        self.appState.activeSession = defaultMatch ?? allSessions.first
                    }
                }
                completion()
            }
        }
    }

    private func fetchTmuxSessions(source: SessionSource, completion: @escaping ([TmuxSession]) -> Void) {
        let script: String
        switch source {
        case .host:
            script = "tmux ls -F \"#{session_name}\" 2>/dev/null || true"
        case .docker(let containerName):
            let safe = appState.sanitizedContainer(containerName)
            script = "docker exec \(safe) tmux ls -F \"#{session_name}\" 2>/dev/null || true"
        }

        let (cmd, args) = appState.remoteCommand(script)

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

    private func fetchDockerContainerSessions(completion: @escaping ([TmuxSession]) -> Void) {
        let listScript = "docker ps --format \"{{.Names}}\" 2>/dev/null || true"
        let (cmd, args) = appState.remoteCommand(listScript)

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

            let source = SessionSource.docker(containerName: containerName)
            fetchTmuxSessions(source: source) { sessions in
                lock.lock()
                if sessions.isEmpty {
                    allDockerSessions.append(TmuxSession(
                        name: "no sessions", source: source, unavailable: true
                    ))
                } else {
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

    /// Manual refresh: tear down and reconnect the active session
    func refreshActiveSession() {
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        if let id = activeSessionID {
            destroyPoolEntry(id)
            activeSessionID = nil
        }

        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.isReconnecting = false
        }

        enumerateAllSessions {
            self.connectToActiveSession()
        }
    }

    private func reconnect() {
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

            self.enumerateAllSessions {
                self.connectToActiveSession()
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

        if wasKeySetup {
            if exitCode != 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.appState.connectionError = "SSH key setup failed. Use ⌘K → Reconnect to try again."
                    self?.appState.isReconnecting = false
                }
            } else {
                // Key setup succeeded — clean up and start a fresh connection
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if let id = self.activeSessionID {
                        self.destroyPoolEntry(id)
                        self.activeSessionID = nil
                    }
                    self.reconnectAttempt = 0
                    self.enumerateAllSessions {
                        self.connectToActiveSession()
                    }
                }
            }
            return
        }

        // Background session died — destroy its pool entry so next switch gets a fresh view
        guard terminatedSessionID == activeSessionID else {
            if let id = terminatedSessionID {
                destroyPoolEntry(id)
            }
            return
        }

        // Active session died — auto-reconnect
        DispatchQueue.main.async { [weak self] in
            if self?.appState.connectionError != nil {
                self?.appState.isReconnecting = false
                return
            }
            self?.reconnect()
        }
    }
}
