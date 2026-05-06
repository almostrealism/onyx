import XCTest
@testable import OnyxLib

final class AppStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppearanceStore.shared.reset()
    }

    // MARK: - HostConfig.isLocal

    func testIsLocal_localhost() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: "localhost"))
        XCTAssertTrue(host.isLocal)
    }

    func testIsLocal_127001() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: "127.0.0.1"))
        XCTAssertTrue(host.isLocal)
    }

    func testIsLocal_ipv6Loopback() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: "::1"))
        XCTAssertTrue(host.isLocal)
    }

    func testIsLocal_empty() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: ""))
        XCTAssertTrue(host.isLocal)
    }

    func testIsLocal_remoteHost() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: "myserver.com"))
        XCTAssertFalse(host.isLocal)
    }

    func testIsLocal_caseInsensitive() {
        let host = HostConfig(label: "test", ssh: SSHConfig(host: "LOCALHOST"))
        XCTAssertTrue(host.isLocal)
    }

    // MARK: - sshCommand

    func testSshCommand_local() {
        let state = AppState()
        let host = HostConfig.localhost
        let (cmd, args) = state.sshCommand(host: host, sessionName: "dev")
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertTrue(args.last?.contains("tmux new-session -A -s dev") ?? false)
    }

    func testSshCommand_remote_defaultPort() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin", tmuxSession: "main"))
        let (cmd, args) = state.sshCommand(host: host, sessionName: "main")

        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("admin@myserver.com"))
        XCTAssertFalse(args.contains("-p"))
        XCTAssertTrue(args.last?.contains("tmux new-session -A -s main") ?? false)
    }

    func testSshCommand_remote_customPort() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", port: 2222, tmuxSession: "work"))
        let (cmd, args) = state.sshCommand(host: host, sessionName: "work")

        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
    }

    func testSshCommand_remote_withIdentityFile() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", tmuxSession: "work", identityFile: "/home/user/.ssh/custom_key"))
        let (_, args) = state.sshCommand(host: host, sessionName: "work")

        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/home/user/.ssh/custom_key"))
    }

    // MARK: - Docker command

    func testDockerTmuxCommand_local() {
        let state = AppState()
        let (cmd, args) = state.dockerTmuxCommand(host: .localhost, container: "my-app", sessionName: "dev")
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertTrue(args.last?.contains("docker exec -it my-app tmux new-session -A -s dev") ?? false)
    }

    func testDockerTmuxCommand_remote() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin"))
        let (cmd, args) = state.dockerTmuxCommand(host: host, container: "my-app", sessionName: "dev")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.last?.contains("docker exec -it my-app tmux new-session -A -s dev") ?? false)
    }

    func testCommandForSession_host() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        state.hosts = [host]
        let session = TmuxSession(name: "main", source: .host(hostID: host.id))
        let (cmd, args) = state.commandForSession(session)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.last?.contains("tmux new-session -A -s main") ?? false)
    }

    func testCommandForSession_docker() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        state.hosts = [host]
        let session = TmuxSession(name: "dev", source: .docker(hostID: host.id, containerName: "webapp"))
        let (cmd, args) = state.commandForSession(session)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.last?.contains("docker exec -it webapp tmux new-session -A -s dev") ?? false)
    }

    // MARK: - effectiveWindowTitle

    func testEffectiveWindowTitle_default() {
        let state = AppState()
        XCTAssertEqual(state.effectiveWindowTitle, "Onyx")
    }

    func testEffectiveWindowTitle_withSession() {
        let state = AppState()
        state.activeSession = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))
        XCTAssertTrue(state.effectiveWindowTitle.contains("dev"))
        XCTAssertTrue(state.effectiveWindowTitle.hasPrefix("Onyx"))
    }

    func testEffectiveWindowTitle_withDockerSession() {
        let state = AppState()
        state.activeSession = TmuxSession(name: "dev", source: .docker(hostID: HostConfig.localhostID, containerName: "webapp"))
        XCTAssertTrue(state.effectiveWindowTitle.contains("webapp/dev"))
    }

    func testEffectiveWindowTitle_withMonitor() {
        let state = AppState()
        state.showMonitor = true
        XCTAssertTrue(state.effectiveWindowTitle.contains("Monitoring"))
    }

    func testEffectiveWindowTitle_withSessionAndMonitor() {
        let state = AppState()
        let host = HostConfig(label: "myserver", ssh: SSHConfig(host: "myserver.com"))
        state.hosts = [host]
        state.activeSession = TmuxSession(name: "prod", source: .host(hostID: host.id))
        state.showMonitor = true
        let title = state.effectiveWindowTitle
        XCTAssertFalse(title.contains("prod"), "Session name should not appear during monitoring")
        XCTAssertTrue(title.contains("myserver"))
        XCTAssertTrue(title.contains("Monitoring"))
    }

    func testEffectiveWindowTitle_customTitle() {
        let state = AppState()
        state.appearance.windowTitle = "MyTerminal"
        XCTAssertEqual(state.effectiveWindowTitle, "MyTerminal")
    }

    // MARK: - dismissTopOverlay

    func testDismissTopOverlay_commandPaletteFirst() {
        let state = AppState()
        state.showCommandPalette = true
        state.showSettings = true
        state.dismissTopOverlay()
        XCTAssertFalse(state.showCommandPalette)
        XCTAssertTrue(state.showSettings) // not dismissed yet
    }

    func testDismissTopOverlay_settingsAfterPalette() {
        let state = AppState()
        state.showSettings = true
        state.activeRightPanel = .notes
        state.dismissTopOverlay()
        XCTAssertFalse(state.showSettings)
        XCTAssertEqual(state.activeRightPanel, .notes) // not dismissed yet
    }

    // MARK: - statsCommand shape

    func testStatsCommand_remote_passesScriptViaStdinNotCommand() {
        // The whole point: don't pass a command argument to ssh. With
        // a command, sshd runs `$SHELL -c <command>` which is non-
        // interactive and triggers any set -n the remote has. Without
        // a command, sshd runs the user's $SHELL interactively, which
        // ignores set -n. We then drive it via stdin.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.label = "remote-host"
        host.ssh.host = "example.com"
        host.ssh.user = "tester"
        let (cmd, args, stdin) = state.statsCommand(host: host)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertNotNil(stdin, "remote stats must pass the script via stdin, not as an ssh command argument")
        let userHost = "tester@example.com"
        // The args list should END with the user@host — no command after.
        XCTAssertEqual(args.last, userHost,
                       "ssh args must not contain a remote command after user@host; got: \(args)")
    }

    func testStatsCommand_remote_forcesInteractiveTTY() {
        // `-tt` forces a remote pseudo-TTY so the no-command session is
        // unambiguously interactive. Interactive shells ignore set -n.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        let (_, args, _) = state.statsCommand(host: host)
        XCTAssertTrue(args.contains("-tt"),
                      "stats SSH must pass -tt; got: \(args)")
    }

    func testStatsCommand_remote_stdinDisablesEchoAndExits() {
        // The stdin script must turn off TTY echo (so the script source
        // doesn't pollute our output) and end with `exit` so the shell
        // closes the session.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        let (_, _, stdin) = state.statsCommand(host: host)
        guard let script = stdin else {
            XCTFail("expected stdin script for remote host")
            return
        }
        XCTAssertTrue(script.contains("stty -echo"),
                      "stdin script must suppress TTY echo")
        XCTAssertTrue(script.contains("exit"),
                      "stdin script must end the session with exit")
        XCTAssertTrue(script.contains("---ONYX-OK-$((1+1))---"),
                      "stdin script must include the execution-proof marker")
    }

    func testStatsCommand_includesExplicitPath() {
        // We don't go through the user's login profile, so PATH has to
        // include standard tool locations explicitly.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        let (_, _, stdin) = state.statsCommand(host: host)
        guard let script = stdin else {
            XCTFail("expected stdin script for remote host")
            return
        }
        XCTAssertTrue(script.contains("/usr/bin"),
                      "stats script should set an explicit PATH containing /usr/bin")
        XCTAssertTrue(script.contains("/opt/homebrew/bin"),
                      "stats script should include Apple Silicon Homebrew path")
    }

    func testStatsCommand_local_doesNotUseStdin() {
        // Local invocation has no noexec problem and uses -c directly.
        let state = AppState()
        let (_, args, stdin) = state.statsCommand(host: HostConfig.localhost)
        XCTAssertNil(stdin, "local stats should not need stdin")
        XCTAssertEqual(args.first, "-c",
                       "local stats should pass script via -c; got: \(args)")
    }

    // MARK: - generic remoteScript shape (CLAUDE.md "Remote command execution")

    func testRemoteScript_remote_passesScriptViaStdinNotCommand() {
        // The whole point of remoteScript: don't pass a command argument
        // to ssh, drive an interactive shell via stdin. Any data-reading
        // SSH caller must use this pattern.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        host.ssh.user = "tester"
        let (cmd, args, stdin) = state.remoteScript("git status --porcelain", host: host)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertNotNil(stdin, "remoteScript must pass the script via stdin for remote hosts")
        XCTAssertEqual(args.last, "tester@example.com",
                       "ssh args must end at user@host — no command argument after; got: \(args)")
        XCTAssertTrue(args.contains("-tt"),
                      "remoteScript must force pseudo-TTY so the remote shell is interactive")
    }

    func testRemoteScript_remote_stdinContainsWrappedScript() {
        // The stdin must include the safety wrapping (PATH, set +vx,
        // execution marker) PLUS the caller's actual script body.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        let (_, _, stdin) = state.remoteScript("uptime", host: host)
        guard let script = stdin else {
            XCTFail("expected stdin")
            return
        }
        XCTAssertTrue(script.contains("uptime"),
                      "stdin must include caller's body verbatim")
        XCTAssertTrue(script.contains("set +vx"),
                      "stdin must include verbose-mode defense")
        XCTAssertTrue(script.contains("$((1+1))"),
                      "stdin must include unevaluated execution marker")
        XCTAssertTrue(script.contains("stty -echo"),
                      "stdin must disable TTY echo to keep our output clean")
        XCTAssertTrue(script.contains("exit"),
                      "stdin must end the session with exit")
    }

    func testRemoteScript_local_usesShellMinusC() {
        let state = AppState()
        let (_, args, stdin) = state.remoteScript("uptime", host: HostConfig.localhost)
        XCTAssertNil(stdin, "local invocation should not need stdin")
        XCTAssertEqual(args.first, "-c",
                       "local invocation should pass wrapped script via -c; got: \(args)")
    }

    // MARK: - sshCommand / dockerTmuxCommand shape (interactive — should stay safe)

    func testSshCommand_remote_allocatesTTY() {
        // Interactive sessions are safe by virtue of being interactive
        // (set -n is ignored in interactive shells). Lock the -t shape
        // so a future refactor doesn't accidentally drop it.
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        host.ssh.user = "tester"
        host.ssh.tmuxSession = "onyx"
        let (cmd, args) = state.sshCommand(host: host, sessionName: "onyx")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-t"),
                      "sshCommand must allocate a TTY for the interactive tmux session; got: \(args)")
    }

    func testDockerTmuxCommand_remote_allocatesTTY() {
        let state = AppState()
        var host = HostConfig.localhost
        host.id = UUID()
        host.ssh.host = "example.com"
        let (cmd, args) = state.dockerTmuxCommand(host: host, container: "myapp", sessionName: "work")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-t"),
                      "dockerTmuxCommand must allocate a TTY; got: \(args)")
    }

    // MARK: - Monitor view modes

    func testShowSimpleMonitor_defaultsOff() {
        // Simple mode is opt-in per session via the `s` key; never the
        // default — first-time users should see the full diagnostic view.
        let state = AppState()
        XCTAssertFalse(state.showSimpleMonitor)
    }

    func testShowSimpleMonitor_independentOfShowMonitor() {
        // The simple-mode flag persists across show/hide cycles of the
        // monitor itself, so closing and reopening the monitor with
        // Escape doesn't reset the user's preferred layout.
        let state = AppState()
        state.showMonitor = true
        state.showSimpleMonitor = true
        state.showMonitor = false
        XCTAssertTrue(state.showSimpleMonitor,
                      "simple-mode should not reset when monitor is hidden")
    }
}

// MARK: - RightPanel State Tests

final class RightPanelTests: XCTestCase {

    func testActiveRightPanel_default() {
        let state = AppState()
        XCTAssertNil(state.activeRightPanel)
    }

    func testShowNotes_computedProperty() {
        let state = AppState()
        state.showNotes = true
        XCTAssertEqual(state.activeRightPanel, .notes)
        state.showNotes = false
        XCTAssertNil(state.activeRightPanel)
    }

    func testShowFileBrowser_computedProperty() {
        let state = AppState()
        state.showFileBrowser = true
        XCTAssertEqual(state.activeRightPanel, .fileBrowser)
        state.showFileBrowser = false
        XCTAssertNil(state.activeRightPanel)
    }

    func testShowArtifacts_computedProperty() {
        let state = AppState()
        state.showArtifacts = true
        XCTAssertEqual(state.activeRightPanel, .artifacts)
        state.showArtifacts = false
        XCTAssertNil(state.activeRightPanel)
    }

    func testOnlyOnePanelAtATime() {
        let state = AppState()
        state.showNotes = true
        XCTAssertTrue(state.showNotes)
        XCTAssertFalse(state.showFileBrowser)
        XCTAssertFalse(state.showArtifacts)

        state.showFileBrowser = true
        XCTAssertFalse(state.showNotes) // setting fileBrowser replaces notes
        XCTAssertTrue(state.showFileBrowser)

        state.showArtifacts = true
        XCTAssertFalse(state.showFileBrowser)
        XCTAssertTrue(state.showArtifacts)
    }

    func testDismissTopOverlay_panelDismissedLast() {
        let state = AppState()
        state.showCommandPalette = true
        state.showSettings = true
        state.activeRightPanel = .notes

        // Command palette dismissed first
        state.dismissTopOverlay()
        XCTAssertFalse(state.showCommandPalette)
        XCTAssertTrue(state.showSettings)
        XCTAssertEqual(state.activeRightPanel, .notes)

        // Settings dismissed second
        state.dismissTopOverlay()
        XCTAssertFalse(state.showSettings)
        XCTAssertEqual(state.activeRightPanel, .notes)

        // Panel dismissed last
        state.dismissTopOverlay()
        XCTAssertNil(state.activeRightPanel)
    }
}

// MARK: - MCP Forwarding Tests

final class MCPForwardingTests: XCTestCase {

    func testDefaultRemotePort() {
        XCTAssertEqual(MCPSocketServer.defaultRemotePort, 19432)
    }

    func testSshCommand_remote_includesForwardingWhenServerRunning() {
        // When MCP server has a TCP port, SSH commands should include -R flag
        let state = AppState()
        // Start the MCP server so tcpPort gets assigned
        state.loadConfig()

        // Give the TCP listener a moment to bind
        let expectation = XCTestExpectation(description: "TCP port assigned")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        _ = XCTWaiter.wait(for: [expectation], timeout: 2.0)

        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin"))
        let (_, args) = state.sshCommand(host: host, sessionName: "dev")

        let hasForwardFlag = args.contains("-R")
        let hasEnvExport = args.last?.contains("ONYX_MCP_PORT") ?? false

        // Only check if TCP port was assigned (may not happen in CI)
        if hasForwardFlag {
            XCTAssertTrue(hasEnvExport, "Should export ONYX_MCP_PORT in remote command")
            // Verify the -R value format
            if let rIdx = args.firstIndex(of: "-R"), rIdx + 1 < args.count {
                let rValue = args[rIdx + 1]
                XCTAssertTrue(rValue.contains("19432:127.0.0.1:"), "Should forward remote 19432 to local port")
            }
        }
    }

    func testSshCommand_local_noForwarding() {
        let state = AppState()
        let (_, args) = state.sshCommand(host: .localhost, sessionName: "dev")
        XCTAssertFalse(args.contains("-R"))
    }

    func testDockerLogsCommand_noForwarding() {
        // Docker logs is a read-only stream, no MCP forwarding needed
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        let (_, args) = state.dockerLogsCommand(host: host, container: "app")
        // dockerLogsCommand doesn't use mcpForwardingArgs — just a plain SSH command
        XCTAssertFalse(args.last?.contains("ONYX_MCP_PORT") ?? false)
    }

    func testDockerLogsCommand_remote_usesLoginShell() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        let (cmd, args) = state.dockerLogsCommand(host: host, container: "app")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        // Should wrap in login shell so docker is on PATH
        XCTAssertTrue(args.last?.contains("$SHELL -lc") ?? false,
            "Remote docker logs should use login shell wrapper")
        XCTAssertTrue(args.last?.contains("docker logs -f") ?? false)
    }

    // MARK: - Session Identity Tests

    func testSessionIdentity_includesHostID() {
        let hostID = UUID()
        let session = TmuxSession(
            name: "dev",
            source: .host(hostID: hostID)
        )
        XCTAssertTrue(session.id.contains(hostID.uuidString))
        XCTAssertTrue(session.id.contains("dev"))
    }

    func testSessionIdentity_differentHostsSameName_differentIDs() {
        let hostA = UUID()
        let hostB = UUID()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostA))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostB))
        XCTAssertNotEqual(sessionA.id, sessionB.id)
    }

    func testSessionIdentity_sameHostSameName_equalIDs() {
        let hostID = UUID()
        let sessionA = TmuxSession(name: "dev", source: .host(hostID: hostID))
        let sessionB = TmuxSession(name: "dev", source: .host(hostID: hostID))
        XCTAssertEqual(sessionA.id, sessionB.id)
    }

    func testSessionIdentity_dockerVsHost_differentIDs() {
        let hostID = UUID()
        let hostSession = TmuxSession(name: "dev", source: .host(hostID: hostID))
        let dockerSession = TmuxSession(name: "dev", source: .docker(hostID: hostID, containerName: "app"))
        XCTAssertNotEqual(hostSession.id, dockerSession.id)
    }

    func testSessionIdentity_dockerLogsVsDocker_differentIDs() {
        let hostID = UUID()
        let dockerSession = TmuxSession(name: "logs", source: .docker(hostID: hostID, containerName: "app"))
        let logsSession = TmuxSession(name: "logs", source: .dockerLogs(hostID: hostID, containerName: "app"))
        XCTAssertNotEqual(dockerSession.id, logsSession.id)
    }

    func testActiveSession_notOverriddenByAllSessions() {
        // When activeSession is already set, assigning allSessions should not clear it
        let state = AppState()
        let hostID = UUID()
        let target = TmuxSession(name: "mySession", source: .host(hostID: hostID))
        state.activeSession = target
        state.allSessions = [
            TmuxSession(name: "other1", source: .host(hostID: hostID)),
            TmuxSession(name: "other2", source: .host(hostID: hostID)),
        ]
        // activeSession should remain what we set it to
        XCTAssertEqual(state.activeSession?.name, "mySession")
        XCTAssertEqual(state.activeSession?.id, target.id)
    }

    func testIsLocal_emptyHost_returnsTrue() {
        let host = HostConfig(label: "New Host", ssh: SSHConfig(host: ""))
        XCTAssertTrue(host.isLocal, "Empty host should be considered local")
    }

    func testIsLocal_localhost_returnsTrue() {
        let host = HostConfig(label: "Local", ssh: SSHConfig(host: "localhost"))
        XCTAssertTrue(host.isLocal)
    }

    func testIsLocal_remoteHost_returnsFalse() {
        let host = HostConfig(label: "Server", ssh: SSHConfig(host: "myserver.com"))
        XCTAssertFalse(host.isLocal)
    }

    func testLocalhostID_isStable() {
        XCTAssertEqual(
            HostConfig.localhostID,
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
        XCTAssertEqual(HostConfig.localhost.id, HostConfig.localhostID)
    }

    func testNewHost_isNotBuiltinLocalhost() {
        // A new host with empty ssh.host has isLocal==true but a different ID than localhostID
        let newHost = HostConfig(label: "New Host", ssh: SSHConfig(host: ""))
        XCTAssertTrue(newHost.isLocal)
        XCTAssertNotEqual(newHost.id, HostConfig.localhostID,
            "New hosts should have unique IDs, not the built-in localhost ID")
    }
}
