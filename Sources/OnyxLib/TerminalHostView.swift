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
        if !appState.showSetup && !nsView.hasStarted {
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupTerminal() {
        let tv = LocalProcessTerminalView(frame: bounds)
        tv.autoresizingMask = [.width, .height]

        tv.nativeBackgroundColor = NSColor(white: 0.04, alpha: 0.0)
        tv.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        // SwiftTerm only sets layer?.backgroundColor during init, not when
        // nativeBackgroundColor changes — force the layer transparent
        tv.wantsLayer = true
        tv.layer?.isOpaque = false
        tv.layer?.backgroundColor = CGColor.clear

        let size = CGFloat(appState.appearance.fontSize)
        currentFontSize = appState.appearance.fontSize
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

        // For remote hosts, probe key auth first
        if !appState.isLocal {
            probeAndConnect()
        } else {
            enumerateTmuxSessions {
                DispatchQueue.main.async {
                    let (cmd, args) = self.appState.sshCommand()
                    self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
                }
            }
        }
    }

    func forceReconnect() {
        terminalView?.terminate()
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false
        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }

        if !appState.isLocal {
            probeAndConnect()
        } else {
            enumerateTmuxSessions {
                DispatchQueue.main.async {
                    let (cmd, args) = self.appState.sshCommand()
                    self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
                }
            }
        }
    }

    /// Probe SSH with BatchMode=yes. If key auth works, connect normally.
    /// If it fails, check why and show the appropriate error/key setup prompt.
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
                // Key auth works — enumerate sessions, then connect
                self.enumerateTmuxSessions {
                    DispatchQueue.main.async {
                        self.lastStartTime = Date()
                        let (cmd, args) = self.appState.sshCommand()
                        self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
                    }
                }
            } else {
                // Key auth failed — offer key setup
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
        terminalView?.terminate()
        isKeySetup = true
        reconnectAttempt = 0
        lastStartTime = Date()
        DispatchQueue.main.async {
            self.appState.connectionError = nil
            self.appState.needsKeySetup = false
        }
        let (cmd, args) = appState.keySetupCommand()
        terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
    }

    /// Query the target for existing tmux sessions
    private func enumerateTmuxSessions(then completion: @escaping () -> Void) {
        let script = "tmux ls -F \"#{session_name}\" 2>/dev/null || true"
        let (cmd, args) = appState.remoteCommand(script)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.appState.tmuxSessions = [self.appState.sshConfig.tmuxSession]
                    self.appState.activeSession = self.appState.sshConfig.tmuxSession
                    completion()
                }
                return
            }

            // Read stdout synchronously — output is small, no pipe buffer concern
            let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let sessions = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            DispatchQueue.main.async {
                guard let self = self else { return }
                let defaultSession = self.appState.sshConfig.tmuxSession
                if sessions.isEmpty {
                    self.appState.tmuxSessions = [defaultSession]
                    self.appState.activeSession = defaultSession
                } else {
                    self.appState.tmuxSessions = sessions
                    if self.appState.activeSession.isEmpty || !sessions.contains(self.appState.activeSession) {
                        self.appState.activeSession = sessions.contains(defaultSession) ? defaultSession : sessions[0]
                    }
                }
                completion()
            }
        }
    }

    func switchToSession(_ session: String) {
        terminalView?.terminate()
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        DispatchQueue.main.async {
            self.appState.activeSession = session
            self.appState.connectionError = nil
        }

        let (cmd, args) = appState.sshCommand(session: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
        }
    }

    func createNewTmuxSession() {
        // Generate a name like "onyx-2", "onyx-3", etc.
        let base = appState.sshConfig.tmuxSession
        var idx = 2
        var name = "\(base)-\(idx)"
        while appState.tmuxSessions.contains(name) {
            idx += 1
            name = "\(base)-\(idx)"
        }

        terminalView?.terminate()
        reconnectAttempt = 0
        lastStartTime = Date()
        isKeySetup = false

        DispatchQueue.main.async {
            self.appState.tmuxSessions.append(name)
            self.appState.activeSession = name
            self.appState.connectionError = nil
        }

        let (cmd, args) = appState.sshCommand(session: name)
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

            // Re-enumerate sessions so we connect to one that still exists
            self.enumerateTmuxSessions {
                DispatchQueue.main.async {
                    let (cmd, args) = self.appState.sshCommand()
                    self.terminalView?.startProcess(executable: cmd, args: args, environment: nil, execName: nil)
                }
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

        // If key setup script failed, show error
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
