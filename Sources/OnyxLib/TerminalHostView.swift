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
        if appState.createNewSession {
            DispatchQueue.main.async {
                appState.createNewSession = false
            }
            nsView.createNewTmuxSession()
        }
        nsView.updateFontSize(appState.appearance.fontSize)
    }
}

class OnyxTerminalView: NSView {
    let appState: AppState
    private var terminalView: LocalProcessTerminalView?
    var hasStarted = false
    private var reconnectAttempt = 0
    private let maxBackoff: TimeInterval = 15.0
    private var currentFontSize: Double = 13
    private var lastStartTime: Date?
    private var isKeySetup = false

    init(appState: AppState) {
        self.appState = appState
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = CGColor.clear
        setupTerminal()
        installScrollMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private var scrollMonitor: Any?

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let tv = self.terminalView else { return event }
            guard event.deltaY != 0 else { return event }

            // Only handle if the scroll targets our terminal view
            guard let window = tv.window,
                  let targetView = window.contentView?.hitTest(event.locationInWindow),
                  targetView === tv || targetView.isDescendant(of: tv) else {
                return event
            }

            // If the application (e.g. tmux) has requested mouse events, forward
            // the scroll as button 4/5 presses instead of local buffer scrolling
            guard tv.allowMouseReporting && tv.terminal.mouseMode != .off else {
                return event
            }

            let point = tv.convert(event.locationInWindow, from: nil)
            let cols = CGFloat(tv.terminal.cols)
            let rows = CGFloat(tv.terminal.rows)
            let col = max(0, min(Int(point.x / (tv.frame.width / cols)), tv.terminal.cols - 1))
            let row = max(0, min(Int((tv.frame.height - point.y) / (tv.frame.height / rows)), tv.terminal.rows - 1))

            let lines = max(1, Int(abs(event.deltaY)))
            let button = event.deltaY > 0 ? 64 : 65  // Cb: 64 = scroll up, 65 = scroll down
            for _ in 0..<lines {
                tv.terminal.sendEvent(buttonFlags: button, x: col, y: row)
            }
            return nil  // consume the event
        }
    }

    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupTerminal() {
        let tv = createTerminalView()
        addSubview(tv)
        terminalView = tv
    }

    /// Create a fresh LocalProcessTerminalView with our styling applied
    private func createTerminalView() -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: bounds)
        tv.autoresizingMask = [.width, .height]

        tv.nativeBackgroundColor = NSColor(white: 0.04, alpha: 0.0)
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        // SwiftTerm only sets layer?.backgroundColor during init, not when
        // nativeBackgroundColor changes — force the layer transparent
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

    /// Replace the terminal view with a fresh one (needed because
    /// LocalProcessTerminalView can't start a new process after the old one exits)
    private func resetTerminalView() {
        terminalView?.removeFromSuperview()
        terminalView = nil
        let tv = createTerminalView()
        addSubview(tv)
        terminalView = tv
    }

    func updateFontSize(_ newSize: Double) {
        guard newSize != currentFontSize, let tv = terminalView else { return }
        currentFontSize = newSize
        let size = CGFloat(newSize)
        if let sfMono = NSFont(name: "SF Mono", size: size) {
            tv.font = sfMono
        } else {
            tv.font = NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

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
        resetTerminalView()
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
            self.resetTerminalView()
            self.lastStartTime = Date()
            let session = self.appState.activeSession ?? TmuxSession(name: self.appState.sshConfig.tmuxSession, source: .host)
            let (cmd, args) = self.appState.commandForSession(session)
            self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
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

            // 1. Check if port is open
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

            // 2. Probe key-based auth with BatchMode
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
        resetTerminalView()
        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }
        let (cmd, args) = appState.keySetupCommand()
        terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
    }

    // MARK: - Session Enumeration

    /// Enumerate host tmux sessions + docker container tmux sessions
    private func enumerateAllSessions(then completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let group = DispatchGroup()
            var hostSessions: [TmuxSession] = []
            var dockerSessions: [TmuxSession] = []

            // 1. Host tmux sessions
            group.enter()
            self.fetchTmuxSessions(source: .host) { sessions in
                hostSessions = sessions
                group.leave()
            }

            // 2. Docker container sessions
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
                    // Keep current active if still valid
                    if let current = self.appState.activeSession,
                       allSessions.contains(where: { $0.id == current.id }) {
                        // still valid
                    } else {
                        // Pick default host session or first available
                        let defaultMatch = allSessions.first { $0.source == .host && $0.name == defaultSession }
                        self.appState.activeSession = defaultMatch ?? allSessions.first
                    }
                }
                completion()
            }
        }
    }

    /// Fetch tmux sessions for a given source (host or docker container)
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
            .map { TmuxSession(name: $0, source: source) }

        completion(sessions)
    }

    /// Discover docker containers and their tmux sessions
    private func fetchDockerContainerSessions(completion: @escaping ([TmuxSession]) -> Void) {
        // Step 1: List running containers
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

        // Step 2: For each container, check if tmux exists and list sessions
        var allDockerSessions: [TmuxSession] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for containerName in containerNames {
            group.enter()

            let source = SessionSource.docker(containerName: containerName)
            fetchTmuxSessions(source: source) { sessions in
                lock.lock()
                if sessions.isEmpty {
                    // tmux not available or no sessions — show placeholder
                    allDockerSessions.append(TmuxSession(
                        name: "no tmux", source: source, unavailable: true
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
        resetTerminalView()

        DispatchQueue.main.async {
            self.appState.activeSession = session
            self.appState.connectionError = nil
        }

        let (cmd, args) = appState.commandForSession(session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
        }
    }

    func createNewTmuxSession() {
        let base = appState.sshConfig.tmuxSession
        let existingNames = appState.hostSessionNames
        var idx = 2
        var name = "\(base)-\(idx)"
        while existingNames.contains(name) {
            idx += 1
            name = "\(base)-\(idx)"
        }

        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false
        resetTerminalView()

        let newSession = TmuxSession(name: name, source: .host)
        DispatchQueue.main.async {
            self.appState.allSessions.append(newSession)
            self.appState.activeSession = newSession
            self.appState.connectionError = nil
        }

        let (cmd, args) = appState.commandForSession(newSession)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
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

            self.enumerateAllSessions {
                self.connectToActiveSession()
            }
        }
    }

}

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

        if wasKeySetup && exitCode != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.appState.connectionError = "SSH key setup failed. Use ⌘K → Reconnect to try again."
                self?.appState.isReconnecting = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            if self?.appState.connectionError != nil {
                self?.appState.isReconnecting = false
                return
            }
            self?.reconnect()
        }
    }
}
