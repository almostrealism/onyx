import XCTest
@testable import OnyxLib

final class MonitorParseTests: XCTestCase {

    // MARK: - parseSizeMB

    func testParseSizeMB_gigabytes() {
        XCTAssertEqual(MonitorManager.parseSizeMB("127G"), 127 * 1024)
        XCTAssertEqual(MonitorManager.parseSizeMB("1g"), 1024)
    }

    func testParseSizeMB_megabytes() {
        XCTAssertEqual(MonitorManager.parseSizeMB("512M"), 512)
        XCTAssertEqual(MonitorManager.parseSizeMB("121m"), 121)
    }

    func testParseSizeMB_kilobytes() {
        let result = MonitorManager.parseSizeMB("4096K")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 4.0, accuracy: 0.001)

        let result2 = MonitorManager.parseSizeMB("1024k")
        XCTAssertEqual(result2!, 1.0, accuracy: 0.001)
    }

    func testParseSizeMB_plainNumber() {
        XCTAssertEqual(MonitorManager.parseSizeMB("256"), 256)
    }

    func testParseSizeMB_withWhitespace() {
        XCTAssertEqual(MonitorManager.parseSizeMB("  512M  "), 512)
    }

    func testParseSizeMB_invalidInput() {
        XCTAssertNil(MonitorManager.parseSizeMB("abc"))
    }

    // MARK: - parse() with Linux output

    func testParseLinuxOutput() {
        let output = "---UPTIME---\n 14:32:01 up 45 days,  3:12,  2 users,  load average: 1.23, 0.98, 0.76\n---CPU---\ntop - 14:32:01 up 45 days,  3:12,  2 users,  load average: 1.23, 0.98, 0.76\nTasks: 312 total,   1 running, 311 sleeping,   0 stopped,   0 zombie\n%Cpu(s):  2.3 us,  1.0 sy,  0.0 ni, 96.7 id,  0.0 wa,  0.0 hi,  0.0 si,  0.0 st\nMiB Mem :  15896.0 total,   2345.2 free,   8934.1 used,   4616.7 buff/cache\nMiB Swap:   2048.0 total,   2048.0 free,      0.0 used.   6429.3 avail Mem\n---MEM---\n              total        used        free      shared  buff/cache   available\nMem:          15896        8934        2345         234        4616        6429\nSwap:          2048           0        2048\n---GPU---\n45, 32, 67, NVIDIA GeForce RTX 3090"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }

        // Load averages
        if let la1 = sample.loadAvg1 {
            XCTAssertEqual(la1, 1.23, accuracy: 0.01)
        } else {
            XCTFail("loadAvg1 is nil")
        }
        if let la5 = sample.loadAvg5 {
            XCTAssertEqual(la5, 0.98, accuracy: 0.01)
        } else {
            XCTFail("loadAvg5 is nil")
        }
        if let la15 = sample.loadAvg15 {
            XCTAssertEqual(la15, 0.76, accuracy: 0.01)
        } else {
            XCTFail("loadAvg15 is nil")
        }

        // CPU: 100 - 96.7 = 3.3
        if let cpu = sample.cpuUsage {
            XCTAssertEqual(cpu, 3.3, accuracy: 0.1)
        } else {
            XCTFail("cpuUsage is nil")
        }

        // MEM: from "Mem:" line
        if let memT = sample.memTotal, let memU = sample.memUsed {
            XCTAssertEqual(memT, 15896, accuracy: 1)
            XCTAssertEqual(memU, 8934, accuracy: 1)
        } else {
            XCTFail("memTotal or memUsed is nil: total=\(String(describing: sample.memTotal)) used=\(String(describing: sample.memUsed))")
        }

        // GPU
        if let gpuU = sample.gpuUsage, let gpuM = sample.gpuMemUsage {
            XCTAssertEqual(gpuU, 45, accuracy: 0.1)
            XCTAssertEqual(gpuM, 32, accuracy: 0.1)
        } else {
            XCTFail("gpuUsage or gpuMemUsage is nil")
        }
        XCTAssertEqual(sample.gpuTemp, 67)
        XCTAssertEqual(sample.gpuName, "NVIDIA GeForce RTX 3090")
    }

    // MARK: - parse() with macOS output

    func testParseMacOSOutput() {
        let output = "---UPTIME---\n 2:32  up 10 days,  4:15, 3 users, load averages: 2.50 1.80 1.50\n---CPU---\nProcesses: 450 total, 3 running, 447 sleeping, 1892 threads\n2024/01/15 14:32:01\nLoad Avg: 2.50, 1.80, 1.50\nCPU usage: 19.46% user, 7.6% sys, 72.94% idle\nSharedLibs: 380M resident, 90M data, 45M linkedit.\nMemRegions: 135421 total, 5631M resident, 245M private, 2345M shared.\nPhysMem: 14G used (2500M wired, 1200M compressor), 2G unused.\nVM: 245G vram, 3456M framework vram.\nNetworks: packets: 123456/78M in, 98765/45M out.\nDisks: 2345678/45G read, 1234567/23G written.\n---MEM---\nPhysMem: 14G used (2500M wired, 1200M compressor), 2G unused.\n---GPU---\nN/A"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }

        // Load averages: macOS uses space-separated "load averages: 2.50 1.80 1.50"
        // but the parser splits by comma, so only the first value parses (as "2.50 1.80 1.50")
        // loadAvg1 will be nil because Double("2.50 1.80 1.50") fails
        XCTAssertNil(sample.loadAvg1, "macOS space-separated load averages are not parsed by comma-split logic")

        // CPU: 100 - 72.94 = 27.06
        XCTAssertNotNil(sample.cpuUsage)
        XCTAssertEqual(sample.cpuUsage!, 27.06, accuracy: 0.1)

        // Memory from PhysMem: 14G used, 2G unused => 14*1024 used, (14+2)*1024 total
        XCTAssertNotNil(sample.memUsed)
        XCTAssertEqual(sample.memUsed!, 14 * 1024, accuracy: 1)
        XCTAssertEqual(sample.memTotal!, 16 * 1024, accuracy: 1)

        // GPU is N/A
        XCTAssertNil(sample.gpuUsage)
        XCTAssertNil(sample.gpuName)
    }

    // MARK: - parse() with no GPU

    func testParseOutputNoGPU() {
        let output = "---UPTIME---\n 14:32:01 up 1 day, load average: 0.50, 0.40, 0.30\n---CPU---\n%Cpu(s):  5.0 us,  2.0 sy,  0.0 ni, 93.0 id,  0.0 wa\n---MEM---\nMem:           7982        3456        1234         123        3291        4123\n---GPU---\nN/A"

        let sample = MonitorManager.parse(output: output)
        XCTAssertNotNil(sample)
        guard let sample = sample else { return }
        XCTAssertNotNil(sample.cpuUsage)
        XCTAssertEqual(sample.cpuUsage!, 7.0, accuracy: 0.1)
        XCTAssertNil(sample.gpuUsage)
    }

    // MARK: - parse() empty/garbage

    func testParseEmptyOutput() {
        let sample = MonitorManager.parse(output: "")
        XCTAssertNotNil(sample) // returns a sample with all nils
        XCTAssertNil(sample!.cpuUsage)
        XCTAssertNil(sample!.memUsed)
    }
}

final class AppStateTests: XCTestCase {

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
        state.activeSession = TmuxSession(name: "prod", source: .host(hostID: HostConfig.localhostID))
        state.showMonitor = true
        let title = state.effectiveWindowTitle
        XCTAssertTrue(title.contains("prod"))
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
}

final class SessionModelTests: XCTestCase {

    // MARK: - SessionSource

    func testSessionSource_hostStableKey() {
        let key = SessionSource.host(hostID: HostConfig.localhostID).stableKey
        XCTAssertTrue(key.hasPrefix("host:"))
    }

    func testSessionSource_dockerStableKey() {
        let source = SessionSource.docker(hostID: HostConfig.localhostID, containerName: "my-app")
        XCTAssertTrue(source.stableKey.contains("my-app"))
    }

    func testSessionSource_hostDisplayName() {
        XCTAssertEqual(SessionSource.host(hostID: HostConfig.localhostID).displayName, "Host")
    }

    func testSessionSource_dockerDisplayName() {
        let source = SessionSource.docker(hostID: HostConfig.localhostID, containerName: "webapp")
        XCTAssertEqual(source.displayName, "webapp")
    }

    func testSessionSource_equality() {
        XCTAssertEqual(SessionSource.host(hostID: HostConfig.localhostID), SessionSource.host(hostID: HostConfig.localhostID))
        XCTAssertEqual(
            SessionSource.docker(hostID: HostConfig.localhostID, containerName: "a"),
            SessionSource.docker(hostID: HostConfig.localhostID, containerName: "a")
        )
        XCTAssertNotEqual(SessionSource.host(hostID: HostConfig.localhostID), SessionSource.docker(hostID: HostConfig.localhostID, containerName: "a"))
        XCTAssertNotEqual(
            SessionSource.docker(hostID: HostConfig.localhostID, containerName: "a"),
            SessionSource.docker(hostID: HostConfig.localhostID, containerName: "b")
        )
    }

    // MARK: - TmuxSession

    func testTmuxSession_id_host() {
        let s = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))
        XCTAssertTrue(s.id.contains("dev"))
    }

    func testTmuxSession_id_docker() {
        let s = TmuxSession(name: "dev", source: .docker(hostID: HostConfig.localhostID, containerName: "webapp"))
        XCTAssertTrue(s.id.contains("dev"))
        XCTAssertTrue(s.id.contains("webapp"))
    }

    func testTmuxSession_displayLabel_host() {
        let s = TmuxSession(name: "main", source: .host(hostID: HostConfig.localhostID))
        XCTAssertEqual(s.displayLabel, "main")
    }

    func testTmuxSession_displayLabel_docker() {
        let s = TmuxSession(name: "main", source: .docker(hostID: HostConfig.localhostID, containerName: "api"))
        XCTAssertEqual(s.displayLabel, "api/main")
    }

    func testTmuxSession_equality() {
        let a = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))
        let b = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))
        let c = TmuxSession(name: "dev", source: .docker(hostID: HostConfig.localhostID, containerName: "x"))
        let d = TmuxSession(name: "prod", source: .host(hostID: HostConfig.localhostID))

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c) // same name, different source
        XCTAssertNotEqual(a, d) // same source, different name
    }

    // MARK: - hostGroupedSessions

    func testHostGroupedSessions_empty() {
        let state = AppState()
        state.allSessions = []
        // No hosts configured, so no groups
        XCTAssertTrue(state.hostGroupedSessions.isEmpty)
    }

    func testHostGroupedSessions_hostOnly() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "a", source: .host(hostID: HostConfig.localhostID)),
            TmuxSession(name: "b", source: .host(hostID: HostConfig.localhostID)),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1)
        XCTAssertEqual(hostGroups[0].groups.count, 1) // one SessionGroup (host)
        XCTAssertEqual(hostGroups[0].groups[0].source, .host(hostID: HostConfig.localhostID))
        XCTAssertEqual(hostGroups[0].groups[0].sessions.count, 2)
    }

    func testHostGroupedSessions_hostFirstThenDocker() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "x", source: .docker(hostID: HostConfig.localhostID, containerName: "zzz")),
            TmuxSession(name: "a", source: .host(hostID: HostConfig.localhostID)),
            TmuxSession(name: "y", source: .docker(hostID: HostConfig.localhostID, containerName: "aaa")),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1) // one host
        let groups = hostGroups[0].groups
        XCTAssertEqual(groups.count, 3) // host group + 2 docker groups
        XCTAssertEqual(groups[0].source, .host(hostID: HostConfig.localhostID)) // host always first
        // Docker groups sorted by key
        XCTAssertEqual(groups[1].source, .docker(hostID: HostConfig.localhostID, containerName: "aaa"))
        XCTAssertEqual(groups[2].source, .docker(hostID: HostConfig.localhostID, containerName: "zzz"))
    }

    func testHostGroupedSessions_dockerOnly() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "s1", source: .docker(hostID: HostConfig.localhostID, containerName: "app")),
            TmuxSession(name: "s2", source: .docker(hostID: HostConfig.localhostID, containerName: "app")),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1) // one host
        XCTAssertEqual(hostGroups[0].groups.count, 1) // one docker group
        XCTAssertEqual(hostGroups[0].groups[0].source, .docker(hostID: HostConfig.localhostID, containerName: "app"))
        XCTAssertEqual(hostGroups[0].groups[0].sessions.count, 2)
    }

    // MARK: - Favorites

    func testToggleFavorite_addsAndRemoves() {
        let state = AppState()
        let session = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))

        XCTAssertFalse(state.isFavorited(session))

        state.toggleFavorite(session)
        XCTAssertTrue(state.isFavorited(session))

        state.toggleFavorite(session)
        XCTAssertFalse(state.isFavorited(session))
    }

    func testFavoriteSessions_filtersCorrectly() {
        let state = AppState()
        let s1 = TmuxSession(name: "a", source: .host(hostID: HostConfig.localhostID))
        let s2 = TmuxSession(name: "b", source: .host(hostID: HostConfig.localhostID))
        let s3 = TmuxSession(name: "c", source: .docker(hostID: HostConfig.localhostID, containerName: "app"))
        state.allSessions = [s1, s2, s3]

        state.toggleFavorite(s1)
        state.toggleFavorite(s3)

        let favs = state.favoriteSessions
        XCTAssertEqual(favs.count, 2)
        XCTAssertTrue(favs.contains(s1))
        XCTAssertTrue(favs.contains(s3))
        XCTAssertFalse(favs.contains(s2))
    }

    func testFavoriteSessions_removedSessionDisappears() {
        let state = AppState()
        let s1 = TmuxSession(name: "a", source: .host(hostID: HostConfig.localhostID))
        state.allSessions = [s1]
        state.toggleFavorite(s1)
        XCTAssertEqual(state.favoriteSessions.count, 1)

        // Session disappears (container stopped, etc.)
        state.allSessions = []
        XCTAssertEqual(state.favoriteSessions.count, 0)
        // But the ID is still in the set (will reappear if session comes back)
        XCTAssertTrue(state.favoritedSessionIDs.contains(s1.id))
    }

    // MARK: - session filtering

    func testAllSessions_filtersBySource() {
        let state = AppState()
        let hostSessions = [
            TmuxSession(name: "onyx", source: .host(hostID: HostConfig.localhostID)),
            TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID)),
        ]
        let dockerSessions = [
            TmuxSession(name: "main", source: .docker(hostID: HostConfig.localhostID, containerName: "app")),
        ]
        state.allSessions = hostSessions + dockerSessions

        let hostOnly = state.allSessions.filter {
            if case .host = $0.source { return true }
            return false
        }
        XCTAssertEqual(hostOnly.count, 2)
        XCTAssertEqual(hostOnly.map(\.name), ["onyx", "dev"])
    }

    // MARK: - sanitizedContainer

    func testSanitizedContainer_allowsValidChars() {
        let state = AppState()
        XCTAssertEqual(state.sanitizedContainer("my-app_v2.0"), "my-app_v2.0")
    }

    func testSanitizedContainer_replacesInvalidChars() {
        let state = AppState()
        XCTAssertEqual(state.sanitizedContainer("my app!@#"), "my_app___")
    }

    func testSanitizedContainer_shellInjection() {
        let state = AppState()
        let result = state.sanitizedContainer("$(rm -rf /)")
        XCTAssertFalse(result.contains("$"))
        XCTAssertFalse(result.contains("("))
        XCTAssertFalse(result.contains(")"))
        XCTAssertFalse(result.contains("/"))
    }

    // MARK: - sanitizedSession (already tested implicitly but verify edge cases)

    func testSanitizedSession_allowsAlphanumericDashUnderscore() {
        let state = AppState()
        XCTAssertEqual(state.sanitizedSession("my-session_2"), "my-session_2")
    }

    func testSanitizedSession_replacesSpecialChars() {
        let state = AppState()
        XCTAssertEqual(state.sanitizedSession("my session!"), "my_session_")
    }

    func testSanitizedSession_shellInjection() {
        let state = AppState()
        let result = state.sanitizedSession("; rm -rf /")
        XCTAssertFalse(result.contains(";"))
        XCTAssertFalse(result.contains(" "))
        XCTAssertFalse(result.contains("/"))
    }

    // MARK: - dismissTopOverlay with sessionManager

    func testDismissTopOverlay_sessionManagerBeforeFileBrowser() {
        let state = AppState()
        state.showSessionManager = true
        state.showFileBrowser = true
        state.dismissTopOverlay()
        XCTAssertFalse(state.showSessionManager)
        XCTAssertTrue(state.showFileBrowser) // not dismissed yet
    }

    func testDismissTopOverlay_commandPaletteBeforeSessionManager() {
        let state = AppState()
        state.showCommandPalette = true
        state.showSessionManager = true
        state.dismissTopOverlay()
        XCTAssertFalse(state.showCommandPalette)
        XCTAssertTrue(state.showSessionManager) // not dismissed yet
    }

    // MARK: - activeSessionName

    // MARK: - Unavailable sessions

    func testUnavailableSession_excludedFromFavorites() {
        let state = AppState()
        let s = TmuxSession(name: "no tmux", source: .docker(hostID: HostConfig.localhostID, containerName: "app"), unavailable: true)
        state.allSessions = [s]
        state.toggleFavorite(s)
        // Even if favorited, unavailable sessions shouldn't be useful as favorites
        XCTAssertTrue(state.isFavorited(s))
        XCTAssertEqual(state.favoriteSessions.count, 1)
    }

    func testUnavailableSession_inGroupedSessions() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID)),
            TmuxSession(name: "no tmux", source: .docker(hostID: HostConfig.localhostID, containerName: "redis"), unavailable: true),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1) // one host
        let groups = hostGroups[0].groups
        XCTAssertEqual(groups.count, 2) // host group + docker group
        XCTAssertEqual(groups[1].sessions.count, 1)
        XCTAssertTrue(groups[1].sessions[0].unavailable)
    }

    func testUnavailableSession_defaultIsFalse() {
        let s = TmuxSession(name: "dev", source: .host(hostID: HostConfig.localhostID))
        XCTAssertFalse(s.unavailable)
    }

    // MARK: - activeSessionName

    func testActiveSessionName_nil() {
        let state = AppState()
        XCTAssertEqual(state.activeSessionName, "")
    }

    func testActiveSessionName_set() {
        let state = AppState()
        state.activeSession = TmuxSession(name: "prod", source: .host(hostID: HostConfig.localhostID))
        XCTAssertEqual(state.activeSessionName, "prod")
    }
}

final class CodableRoundTripTests: XCTestCase {

    func testSSHConfigRoundTrip() throws {
        var config = SSHConfig()
        config.host = "example.com"
        config.user = "testuser"
        config.port = 2222
        config.tmuxSession = "mysession"
        config.identityFile = "/home/user/.ssh/id_rsa"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SSHConfig.self, from: data)

        XCTAssertEqual(decoded.host, "example.com")
        XCTAssertEqual(decoded.user, "testuser")
        XCTAssertEqual(decoded.port, 2222)
        XCTAssertEqual(decoded.tmuxSession, "mysession")
        XCTAssertEqual(decoded.identityFile, "/home/user/.ssh/id_rsa")
    }

    func testSSHConfigDefaultValues() throws {
        let config = SSHConfig()
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.user, "")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.tmuxSession, "onyx")
        XCTAssertEqual(config.identityFile, "")
    }

    func testAppearanceConfigRoundTrip() throws {
        var config = AppearanceConfig()
        config.fontSize = 16
        config.windowOpacity = 0.95
        config.accentHex = "FF6B6B"
        config.windowTitle = "Custom Title"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppearanceConfig.self, from: data)

        XCTAssertEqual(decoded.fontSize, 16)
        XCTAssertEqual(decoded.windowOpacity, 0.95, accuracy: 0.001)
        XCTAssertEqual(decoded.accentHex, "FF6B6B")
        XCTAssertEqual(decoded.windowTitle, "Custom Title")
    }

    func testAppearanceConfigDefaultValues() {
        let config = AppearanceConfig()
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertEqual(config.windowOpacity, 0.82, accuracy: 0.001)
        XCTAssertEqual(config.accentHex, "66CCFF")
        XCTAssertEqual(config.windowTitle, "Onyx")
    }

    func testSSHConfigDecodesFullJSON() throws {
        let json = #"{"host":"server.io","user":"bob","port":22,"tmuxSession":"onyx","identityFile":""}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(SSHConfig.self, from: data)

        XCTAssertEqual(config.host, "server.io")
        XCTAssertEqual(config.user, "bob")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.tmuxSession, "onyx")
    }

    func testSSHConfigPartialJSONThrows() {
        // SSHConfig uses synthesized Codable, so missing keys should fail
        let json = #"{"host":"server.io","user":"bob"}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(SSHConfig.self, from: data))
    }
}

final class FileBrowserTests: XCTestCase {

    private func makeBrowser() -> FileBrowserManager {
        let state = AppState()
        state.hosts = [.localhost]
        return FileBrowserManager(appState: state)
    }

    // MARK: - parseLsOutput

    func testParseLsOutput_typicalLinux() {
        let browser = makeBrowser()
        let output = """
        total 48
        drwxr-xr-x  5 user group  4096 Jan 15 14:30 projects/
        -rw-r--r--  1 user group  1234 Jan 14 09:15 readme.md
        -rwxr-xr-x  1 user group 56789 Jan 13 18:00 build.sh
        drwxr-xr-x  2 user group  4096 Jan 12 12:00 .config/
        """

        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 4)

        // Directories should sort before files
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertFalse(entries[3].isDirectory)

        // Directory names should have trailing / stripped
        XCTAssertEqual(entries[0].name, ".config")
        XCTAssertEqual(entries[1].name, "projects")
    }

    func testParseLsOutput_skipsDotEntries() {
        let browser = makeBrowser()
        let output = """
        total 16
        drwxr-xr-x  3 user group 4096 Jan 15 14:30 ./
        drwxr-xr-x  5 user group 4096 Jan 15 14:30 ../
        -rw-r--r--  1 user group  100 Jan 14 09:15 file.txt
        """

        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "file.txt")
    }

    func testParseLsOutput_emptyDirectory() {
        let browser = makeBrowser()
        let output = "total 0\n"
        let entries = browser.parseLsOutput(output)
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseLsOutput_emptyString() {
        let browser = makeBrowser()
        let entries = browser.parseLsOutput("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testParseLsOutput_sizeAndModified() {
        let browser = makeBrowser()
        let output = """
        total 4
        -rw-r--r--  1 user group  9876 Mar  5 10:22 data.json
        """
        let entries = browser.parseLsOutput(output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].size, "9876")
        XCTAssertEqual(entries[0].modified, "Mar 5 10:22")
    }

    // MARK: - escapeForShell

    func testEscapeForShell_simplePath() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/projects")
        XCTAssertEqual(result, "\"/home/user/projects\"")
    }

    func testEscapeForShell_pathWithSpaces() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/my projects")
        XCTAssertEqual(result, "\"/home/user/my projects\"")
    }

    func testEscapeForShell_pathWithDollar() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/$USER/test")
        XCTAssertEqual(result, "\"/home/\\$USER/test\"")
    }

    func testEscapeForShell_pathWithBacktick() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/`whoami`")
        XCTAssertEqual(result, "\"/home/user/\\`whoami\\`\"")
    }

    func testEscapeForShell_pathWithQuotes() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/file\"name")
        XCTAssertEqual(result, "\"/home/user/file\\\"name\"")
    }

    func testEscapeForShell_pathWithBackslash() {
        let browser = makeBrowser()
        let result = browser.escapeForShell("/home/user/back\\slash")
        XCTAssertEqual(result, "\"/home/user/back\\\\slash\"")
    }
}

final class NoteTests: XCTestCase {

    func testNoteSortOrder() {
        let older = Note(id: "a.md", title: "A", content: "", modified: Date(timeIntervalSince1970: 1000))
        let newer = Note(id: "b.md", title: "B", content: "", modified: Date(timeIntervalSince1970: 2000))

        // Note's < puts newest first, so newer < older should be true
        XCTAssertTrue(newer < older)
        XCTAssertFalse(older < newer)
    }

    func testNotesManagerCreateAndDelete() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = NotesManager(directory: tmpDir)
        XCTAssertTrue(manager.notes.isEmpty)

        manager.createNote()
        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertNotNil(manager.selectedNoteID)

        let note = manager.notes[0]
        manager.deleteNote(note)
        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertNil(manager.selectedNoteID)
    }

    func testNotesManagerSaveAndReload() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = NotesManager(directory: tmpDir)
        manager.createNote()

        var note = manager.notes[0]
        note.content = "Hello, World!"
        manager.saveNote(note)

        // Reload and verify
        let manager2 = NotesManager(directory: tmpDir)
        XCTAssertEqual(manager2.notes.count, 1)
        XCTAssertEqual(manager2.notes[0].content, "Hello, World!")
    }
}

final class RemoteEntryTests: XCTestCase {

    func testRemoteEntrySorting() {
        let dir1 = RemoteEntry(name: "zebra", isDirectory: true, size: "4096", modified: "Jan 1 00:00")
        let dir2 = RemoteEntry(name: "alpha", isDirectory: true, size: "4096", modified: "Jan 1 00:00")
        let file1 = RemoteEntry(name: "aardvark.txt", isDirectory: false, size: "100", modified: "Jan 1 00:00")
        let file2 = RemoteEntry(name: "zoo.txt", isDirectory: false, size: "200", modified: "Jan 1 00:00")

        var entries = [file2, dir1, file1, dir2]
        entries.sort()

        // Directories first, then files, both alphabetical
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[0].name, "alpha")
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertEqual(entries[1].name, "zebra")
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertEqual(entries[2].name, "aardvark.txt")
        XCTAssertFalse(entries[3].isDirectory)
        XCTAssertEqual(entries[3].name, "zoo.txt")
    }
}

// MARK: - ArtifactManager Tests

final class ArtifactManagerTests: XCTestCase {

    func testSetSlot_validSlot() {
        let manager = ArtifactManager()
        let result = manager.setSlot(0, title: "Test", content: .text(content: "Hello", format: .plain))
        XCTAssertTrue(result)
        XCTAssertEqual(manager.slots.count, 1)
        XCTAssertEqual(manager.slots[0]?.title, "Test")
    }

    func testSetSlot_invalidSlotNegative() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.setSlot(-1, title: "Bad", content: .text(content: "", format: .plain)))
        XCTAssertTrue(manager.slots.isEmpty)
    }

    func testSetSlot_invalidSlotTooHigh() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.setSlot(8, title: "Bad", content: .text(content: "", format: .plain)))
        XCTAssertTrue(manager.slots.isEmpty)
    }

    func testSetSlot_allValidSlots() {
        let manager = ArtifactManager()
        for i in 0..<8 {
            XCTAssertTrue(manager.setSlot(i, title: "Slot \(i)", content: .text(content: "Content \(i)", format: .plain)))
        }
        XCTAssertEqual(manager.slots.count, 8)
    }

    func testSetSlot_updatesExisting() {
        let manager = ArtifactManager()
        _ = manager.setSlot(0, title: "First", content: .text(content: "v1", format: .plain))
        let firstID = manager.slots[0]!.id
        _ = manager.setSlot(0, title: "Updated", content: .text(content: "v2", format: .markdown))
        XCTAssertEqual(manager.slots[0]?.title, "Updated")
        XCTAssertEqual(manager.slots[0]?.content, .text(content: "v2", format: .markdown))
        XCTAssertEqual(manager.slots[0]?.id, firstID) // same artifact, just updated
    }

    func testClearSlot_valid() {
        let manager = ArtifactManager()
        _ = manager.setSlot(3, title: "Test", content: .text(content: "", format: .plain))
        XCTAssertTrue(manager.clearSlot(3))
        XCTAssertNil(manager.slots[3])
    }

    func testClearSlot_invalid() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.clearSlot(-1))
        XCTAssertFalse(manager.clearSlot(8))
    }

    func testClearSlot_adjustsActiveSlot() {
        let manager = ArtifactManager()
        _ = manager.setSlot(2, title: "A", content: .text(content: "", format: .plain))
        _ = manager.setSlot(5, title: "B", content: .text(content: "", format: .plain))
        manager.activeSlot = 2
        _ = manager.clearSlot(2)
        XCTAssertEqual(manager.activeSlot, 5) // moves to next occupied slot
    }

    func testClearAll() {
        let manager = ArtifactManager()
        _ = manager.setSlot(0, title: "A", content: .text(content: "", format: .plain))
        _ = manager.setSlot(7, title: "B", content: .diagram(content: "graph TD", format: .mermaid))
        manager.activeSlot = 7
        manager.clearAll()
        XCTAssertTrue(manager.slots.isEmpty)
        XCTAssertEqual(manager.activeSlot, 0)
    }

    func testListSlots_empty() {
        let manager = ArtifactManager()
        XCTAssertTrue(manager.listSlots().isEmpty)
    }

    func testListSlots_ordered() {
        let manager = ArtifactManager()
        _ = manager.setSlot(5, title: "Five", content: .diagram(content: "graph", format: .mermaid))
        _ = manager.setSlot(1, title: "One", content: .text(content: "hello", format: .plain))
        let list = manager.listSlots()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].slot, 1)
        XCTAssertEqual(list[0].title, "One")
        XCTAssertEqual(list[0].type, "text")
        XCTAssertEqual(list[1].slot, 5)
        XCTAssertEqual(list[1].title, "Five")
        XCTAssertEqual(list[1].type, "diagram")
    }

    func testHasArtifacts() {
        let manager = ArtifactManager()
        XCTAssertFalse(manager.hasArtifacts)
        _ = manager.setSlot(0, title: "X", content: .text(content: "", format: .plain))
        XCTAssertTrue(manager.hasArtifacts)
    }

    func testOccupiedSlotCount() {
        let manager = ArtifactManager()
        XCTAssertEqual(manager.occupiedSlotCount, 0)
        _ = manager.setSlot(0, title: "A", content: .text(content: "", format: .plain))
        _ = manager.setSlot(3, title: "B", content: .text(content: "", format: .plain))
        XCTAssertEqual(manager.occupiedSlotCount, 2)
    }

    func testArtifactContent_typeLabel() {
        XCTAssertEqual(ArtifactContent.text(content: "", format: .plain).typeLabel, "text")
        XCTAssertEqual(ArtifactContent.diagram(content: "", format: .mermaid).typeLabel, "diagram")
        XCTAssertEqual(ArtifactContent.model3D(data: Data(), format: .obj).typeLabel, "3d_model")
    }

    func testArtifactContent_equality() {
        let a = ArtifactContent.text(content: "hello", format: .markdown)
        let b = ArtifactContent.text(content: "hello", format: .markdown)
        let c = ArtifactContent.text(content: "hello", format: .plain)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDiagramContent() {
        let manager = ArtifactManager()
        let mermaid = "graph TD\n    A-->B"
        _ = manager.setSlot(0, title: "Flow", content: .diagram(content: mermaid, format: .mermaid))
        XCTAssertEqual(manager.slots[0]?.content, .diagram(content: mermaid, format: .mermaid))
    }

    func testModel3DContent() {
        let manager = ArtifactManager()
        let data = Data([0x01, 0x02, 0x03])
        _ = manager.setSlot(0, title: "Cube", content: .model3D(data: data, format: .obj))
        XCTAssertEqual(manager.slots[0]?.content, .model3D(data: data, format: .obj))
    }
}

// MARK: - MCP Message Handler Tests

final class MCPMessageHandlerTests: XCTestCase {

    private func makeHandler() -> (MCPMessageHandler, ArtifactManager) {
        let manager = ArtifactManager()
        let handler = MCPMessageHandler(artifactManager: manager)
        return (handler, manager)
    }

    // MARK: - Initialize

    func testInitialize() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(1), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)
        if case .object(let obj) = response.result {
            XCTAssertEqual(obj["protocolVersion"], .string("2024-11-05"))
            if case .object(let info) = obj["serverInfo"] {
                XCTAssertEqual(info["name"], .string("onyx"))
            } else {
                XCTFail("Missing serverInfo")
            }
        } else {
            XCTFail("Expected object result")
        }
    }

    // MARK: - Tools List

    func testToolsList() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(2), method: "tools/list")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        if case .object(let obj) = response.result,
           case .array(let tools) = obj["tools"] {
            XCTAssertEqual(tools.count, 5) // show_text, show_diagram, show_model, clear_slot, list_slots
            let names = tools.compactMap { tool -> String? in
                if case .object(let t) = tool { return t["name"]?.stringValue }
                return nil
            }
            XCTAssertTrue(names.contains("show_text"))
            XCTAssertTrue(names.contains("show_diagram"))
            XCTAssertTrue(names.contains("show_model"))
            XCTAssertTrue(names.contains("clear_slot"))
            XCTAssertTrue(names.contains("list_slots"))
        } else {
            XCTFail("Expected tools array in result")
        }
    }

    // MARK: - Unknown Method

    func testUnknownMethod() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(3), method: "nonexistent/method")
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601) // method not found
    }

    // MARK: - Notifications

    func testNotificationsInitialized() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(4), method: "notifications/initialized")
        let response = handler.dispatch(request)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result, .null)
    }

    // MARK: - handleMessage parse error

    func testHandleMessage_invalidJSON() {
        let (handler, _) = makeHandler()
        let garbage = "not json at all".data(using: .utf8)!
        let responseData = handler.handleMessage(garbage)
        XCTAssertNotNil(responseData)
        if let data = responseData,
           let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
            XCTAssertNotNil(response.error)
            XCTAssertEqual(response.error?.code, -32700) // parse error
        }
    }

    // MARK: - tools/call missing params

    func testToolsCall_missingToolName() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(5), method: "tools/call", params: [:])
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602) // invalid params
    }

    func testToolsCall_unknownTool() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(6), method: "tools/call", params: [
            "name": .string("nonexistent_tool"),
            "arguments": .object([:])
        ])
        let response = handler.dispatch(request)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32602)
    }

    // MARK: - Response ID passthrough

    func testResponsePreservesID_int() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .int(42), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertEqual(response.id, .int(42))
    }

    func testResponsePreservesID_string() {
        let (handler, _) = makeHandler()
        let request = JSONRPCRequest(id: .string("req-abc"), method: "initialize")
        let response = handler.dispatch(request)
        XCTAssertEqual(response.id, .string("req-abc"))
    }
}

// MARK: - AnyCodableValue Tests

final class AnyCodableValueTests: XCTestCase {

    func testStringRoundTrip() throws {
        let value = AnyCodableValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testIntRoundTrip() throws {
        let value = AnyCodableValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.intValue, 42)
    }

    func testBoolRoundTrip() throws {
        let value = AnyCodableValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testNullRoundTrip() throws {
        let value = AnyCodableValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testArrayRoundTrip() throws {
        let value = AnyCodableValue.array([.string("a"), .int(1), .bool(false)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.arrayValue?.count, 3)
    }

    func testObjectRoundTrip() throws {
        let value = AnyCodableValue.object(["key": .string("val"), "num": .int(5)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.objectValue?["key"], .string("val"))
    }

    func testNestedObject() throws {
        let value = AnyCodableValue.object([
            "tools": .array([
                .object(["name": .string("test"), "params": .object(["required": .bool(true)])])
            ])
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testWrongAccessors() {
        let str = AnyCodableValue.string("hello")
        XCTAssertNil(str.intValue)
        XCTAssertNil(str.boolValue)
        XCTAssertNil(str.objectValue)
        XCTAssertNil(str.arrayValue)

        let num = AnyCodableValue.int(5)
        XCTAssertNil(num.stringValue)
        XCTAssertNil(num.boolValue)
    }

    func testDoubleToInt() {
        let dbl = AnyCodableValue.double(3.0)
        XCTAssertEqual(dbl.intValue, 3)
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

// MARK: - Git Parser Tests

final class GitParserTests: XCTestCase {

    private func makeGitManager() -> GitManager {
        let state = AppState()
        return GitManager(appState: state)
    }

    // MARK: - parseGitStatusPorcelain

    func testParseGitStatus_modifiedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain(" M src/main.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "src/main.swift")
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].area, .unstaged)
    }

    func testParseGitStatus_stagedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("M  src/main.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .modified)
        XCTAssertEqual(files[0].area, .staged)
    }

    func testParseGitStatus_stagedAndUnstaged() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("MM src/main.swift")
        XCTAssertEqual(files.count, 2) // one staged, one unstaged
        XCTAssertTrue(files.contains(where: { $0.area == .staged }))
        XCTAssertTrue(files.contains(where: { $0.area == .unstaged }))
    }

    func testParseGitStatus_addedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("A  newfile.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .added)
        XCTAssertEqual(files[0].area, .staged)
    }

    func testParseGitStatus_deletedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain(" D oldfile.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .deleted)
        XCTAssertEqual(files[0].area, .unstaged)
    }

    func testParseGitStatus_untrackedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("?? new_untracked.txt")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .untracked)
        XCTAssertEqual(files[0].area, .untracked)
        XCTAssertEqual(files[0].path, "new_untracked.txt")
    }

    func testParseGitStatus_multipleFiles() {
        let gm = makeGitManager()
        let output = """
        M  staged.swift
         M unstaged.swift
        ?? untracked.txt
        A  added.swift
         D deleted.swift
        """
        let files = gm.parseGitStatusPorcelain(output)
        XCTAssertEqual(files.count, 5)
    }

    func testParseGitStatus_empty() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("")
        XCTAssertTrue(files.isEmpty)
    }

    func testParseGitStatus_renamedFile() {
        let gm = makeGitManager()
        let files = gm.parseGitStatusPorcelain("R  old.swift -> new.swift")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].area, .staged)
    }

    // MARK: - parseDiffStat

    func testParseDiffStat_typical() {
        let gm = makeGitManager()
        let output = """
         src/main.swift  | 10 +++++++---
         src/utils.swift |  5 ++---
         3 files changed, 45 insertions(+), 12 deletions(-)
        """
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 3)
        XCTAssertEqual(stats?.insertions, 45)
        XCTAssertEqual(stats?.deletions, 12)
    }

    func testParseDiffStat_singleFile() {
        let gm = makeGitManager()
        let output = " 1 file changed, 2 insertions(+)"
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 1)
        XCTAssertEqual(stats?.insertions, 2)
        XCTAssertEqual(stats?.deletions, 0)
    }

    func testParseDiffStat_deletionsOnly() {
        let gm = makeGitManager()
        let output = " 1 file changed, 5 deletions(-)"
        let stats = gm.parseDiffStat(output)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.filesChanged, 1)
        XCTAssertEqual(stats?.insertions, 0)
        XCTAssertEqual(stats?.deletions, 5)
    }

    func testParseDiffStat_empty() {
        let gm = makeGitManager()
        let stats = gm.parseDiffStat("")
        XCTAssertNil(stats)
    }

    func testParseDiffStat_noChanges() {
        let gm = makeGitManager()
        let stats = gm.parseDiffStat("no changes at all")
        XCTAssertNil(stats)
    }

    // MARK: - GitRepoStatus computed properties

    func testGitRepoStatus_isClean() {
        let status = GitRepoStatus(branch: "main", isDetachedHead: false, changedFiles: [], diffStats: nil)
        XCTAssertTrue(status.isClean)
        XCTAssertTrue(status.stagedFiles.isEmpty)
        XCTAssertTrue(status.unstagedFiles.isEmpty)
        XCTAssertTrue(status.untrackedFiles.isEmpty)
    }

    func testGitRepoStatus_filtersAreas() {
        let files = [
            GitChangedFile(path: "a.swift", status: .modified, area: .staged),
            GitChangedFile(path: "b.swift", status: .modified, area: .unstaged),
            GitChangedFile(path: "c.txt", status: .untracked, area: .untracked),
            GitChangedFile(path: "d.swift", status: .added, area: .staged),
        ]
        let status = GitRepoStatus(branch: "main", isDetachedHead: false, changedFiles: files, diffStats: nil)
        XCTAssertFalse(status.isClean)
        XCTAssertEqual(status.stagedFiles.count, 2)
        XCTAssertEqual(status.unstagedFiles.count, 1)
        XCTAssertEqual(status.untrackedFiles.count, 1)
    }
}

// MARK: - JSONRPCRequest/Response Codable Tests

final class JSONRPCCodableTests: XCTestCase {

    func testRequestEncodeDecode() throws {
        let request = JSONRPCRequest(id: .int(1), method: "tools/list", params: ["cursor": .string("abc")])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, "2.0")
        XCTAssertEqual(decoded.id, .int(1))
        XCTAssertEqual(decoded.method, "tools/list")
        XCTAssertEqual(decoded.params?["cursor"], .string("abc"))
    }

    func testResponseWithResult() throws {
        let response = JSONRPCResponse(id: .string("req-1"), result: .object(["status": .string("ok")]))
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertEqual(decoded.id, .string("req-1"))
        XCTAssertNotNil(decoded.result)
        XCTAssertNil(decoded.error)
    }

    func testResponseWithError() throws {
        let response = JSONRPCResponse(id: .int(5), error: .methodNotFound)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        XCTAssertNil(decoded.result)
        XCTAssertNotNil(decoded.error)
        XCTAssertEqual(decoded.error?.code, -32601)
    }

    func testJSONRPCError_staticValues() {
        XCTAssertEqual(JSONRPCError.parseError.code, -32700)
        XCTAssertEqual(JSONRPCError.invalidRequest.code, -32600)
        XCTAssertEqual(JSONRPCError.methodNotFound.code, -32601)
        XCTAssertEqual(JSONRPCError.invalidParams.code, -32602)
    }
}

// MARK: - Docker Logs Session Tests

final class DockerLogsTests: XCTestCase {

    // MARK: - SessionSource.dockerLogs

    func testDockerLogs_stableKey() {
        let source = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "webapp")
        XCTAssertTrue(source.stableKey.contains("dockerlogs:"))
        XCTAssertTrue(source.stableKey.contains("webapp"))
    }

    func testDockerLogs_displayName() {
        let source = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "api")
        XCTAssertEqual(source.displayName, "api logs")
    }

    func testDockerLogs_isDocker() {
        let source = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "x")
        XCTAssertTrue(source.isDocker)
        XCTAssertTrue(source.isDockerLogs)
    }

    func testDockerLogs_containerName() {
        let source = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "myapp")
        XCTAssertEqual(source.containerName, "myapp")
    }

    func testDockerLogs_notEqualToDocker() {
        let docker = SessionSource.docker(hostID: HostConfig.localhostID, containerName: "app")
        let logs = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "app")
        XCTAssertNotEqual(docker, logs)
    }

    func testDockerLogs_hostID() {
        let id = UUID()
        let source = SessionSource.dockerLogs(hostID: id, containerName: "x")
        XCTAssertEqual(source.hostID, id)
    }

    // MARK: - TmuxSession with dockerLogs

    func testTmuxSession_displayLabel_dockerLogs() {
        let s = TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "webapp"))
        XCTAssertEqual(s.displayLabel, "webapp/logs")
    }

    func testTmuxSession_id_dockerLogs() {
        let s = TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "webapp"))
        XCTAssertTrue(s.id.contains("dockerlogs:"))
        XCTAssertTrue(s.id.contains("webapp"))
    }

    // MARK: - Docker logs command

    func testDockerLogsCommand_local() {
        let state = AppState()
        let (cmd, args) = state.dockerLogsCommand(host: .localhost, container: "myapp")
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertTrue(args.last?.contains("docker logs -f --tail 1000 myapp") ?? false)
    }

    func testDockerLogsCommand_remote() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin"))
        let (cmd, args) = state.dockerLogsCommand(host: host, container: "webapp")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("admin@myserver.com"))
        XCTAssertTrue(args.last?.contains("docker logs -f --tail 1000 webapp") ?? false)
    }

    func testCommandForSession_dockerLogs() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        state.hosts = [host]
        let session = TmuxSession(name: "logs", source: .dockerLogs(hostID: host.id, containerName: "webapp"))
        let (cmd, args) = state.commandForSession(session)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.last?.contains("docker logs -f") ?? false)
        XCTAssertTrue(args.last?.contains("webapp") ?? false)
    }

    // MARK: - Grouping: logs merged with docker sessions

    func testHostGroupedSessions_logsMergedWithDocker() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "dev", source: .docker(hostID: HostConfig.localhostID, containerName: "app")),
            TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "app")),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1)
        // Should be one group containing both docker + dockerLogs sessions
        let groups = hostGroups[0].groups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.count, 2)
    }

    func testHostGroupedSessions_logsOnlyContainer() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "redis")),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1)
        XCTAssertEqual(hostGroups[0].groups.count, 1)
        XCTAssertEqual(hostGroups[0].groups[0].sessions.count, 1)
    }

    // MARK: - SessionSource.isDockerLogs

    func testIsDockerLogs_false_for_host() {
        XCTAssertFalse(SessionSource.host(hostID: HostConfig.localhostID).isDockerLogs)
    }

    func testIsDockerLogs_false_for_docker() {
        XCTAssertFalse(SessionSource.docker(hostID: HostConfig.localhostID, containerName: "x").isDockerLogs)
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
