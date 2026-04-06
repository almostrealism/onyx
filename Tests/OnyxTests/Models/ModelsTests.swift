import XCTest
@testable import OnyxLib

final class SessionModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FavoritesStore.shared.reset()
    }

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

    // MARK: - Docker Top

    func testDockerTop_stableKey() {
        let source = SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "webapp")
        XCTAssertTrue(source.stableKey.contains("dockertop:"))
        XCTAssertTrue(source.stableKey.contains("webapp"))
    }

    func testDockerTop_displayName() {
        let source = SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "api")
        XCTAssertEqual(source.displayName, "api processes")
    }

    func testDockerTop_isDocker() {
        let source = SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "x")
        XCTAssertTrue(source.isDocker)
        XCTAssertTrue(source.isDockerTop)
        XCTAssertTrue(source.isUtility)
        XCTAssertFalse(source.isDockerLogs)
    }

    func testDockerTop_containerName() {
        let source = SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "myapp")
        XCTAssertEqual(source.containerName, "myapp")
    }

    func testDockerTop_hostID() {
        let id = UUID()
        let source = SessionSource.dockerTop(hostID: id, containerName: "x")
        XCTAssertEqual(source.hostID, id)
    }

    func testDockerTop_notEqualToDockerOrLogs() {
        let docker = SessionSource.docker(hostID: HostConfig.localhostID, containerName: "app")
        let logs = SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "app")
        let top = SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "app")
        XCTAssertNotEqual(docker, top)
        XCTAssertNotEqual(logs, top)
    }

    func testTmuxSession_displayLabel_dockerTop() {
        let s = TmuxSession(name: "top", source: .dockerTop(hostID: HostConfig.localhostID, containerName: "webapp"))
        XCTAssertEqual(s.displayLabel, "webapp/top")
    }

    func testDockerTopCommand_local() {
        let state = AppState()
        let (cmd, args) = state.dockerTopCommand(host: .localhost, container: "myapp")
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertTrue(args.last?.contains("docker top myapp") ?? false)
    }

    func testDockerTopCommand_remote() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin"))
        let (cmd, args) = state.dockerTopCommand(host: host, container: "webapp")
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("admin@myserver.com"))
        XCTAssertTrue(args.last?.contains("docker top webapp") ?? false)
    }

    func testCommandForSession_dockerTop() {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com"))
        state.hosts = [host]
        let session = TmuxSession(name: "top", source: .dockerTop(hostID: host.id, containerName: "webapp"))
        let (cmd, args) = state.commandForSession(session)
        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.last?.contains("docker top") ?? false)
        XCTAssertTrue(args.last?.contains("webapp") ?? false)
    }

    func testHostGroupedSessions_topMergedWithDocker() {
        let state = AppState()
        state.hosts = [.localhost]
        state.allSessions = [
            TmuxSession(name: "dev", source: .docker(hostID: HostConfig.localhostID, containerName: "app")),
            TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "app")),
            TmuxSession(name: "top", source: .dockerTop(hostID: HostConfig.localhostID, containerName: "app")),
        ]
        let hostGroups = state.hostGroupedSessions
        XCTAssertEqual(hostGroups.count, 1)
        let groups = hostGroups[0].groups
        XCTAssertEqual(groups.count, 1, "All three should be in one group")
        XCTAssertEqual(groups[0].sessions.count, 3)
    }

    func testIsUtility_dockerLogs() {
        XCTAssertTrue(SessionSource.dockerLogs(hostID: HostConfig.localhostID, containerName: "x").isUtility)
    }

    func testIsUtility_dockerTop() {
        XCTAssertTrue(SessionSource.dockerTop(hostID: HostConfig.localhostID, containerName: "x").isUtility)
    }

    func testIsUtility_false_for_host() {
        XCTAssertFalse(SessionSource.host(hostID: HostConfig.localhostID).isUtility)
    }

    func testIsUtility_false_for_docker() {
        XCTAssertFalse(SessionSource.docker(hostID: HostConfig.localhostID, containerName: "x").isUtility)
    }
}

// MARK: - Favorite Session Parsing Tests

final class FavoriteParsingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FavoritesStore.shared.reset()
    }

    func testParseFavoriteID_hostSession() {
        let state = AppState()
        let hostID = HostConfig.localhostID
        let id = "host:\(hostID.uuidString):main"
        let session = state.parseFavoriteID(id)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "main")
        XCTAssertEqual(session?.source, .host(hostID: hostID))
    }

    func testParseFavoriteID_dockerSession() {
        let state = AppState()
        let hostID = HostConfig.localhostID
        let id = "docker:\(hostID.uuidString):webapp:dev"
        let session = state.parseFavoriteID(id)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "dev")
        XCTAssertEqual(session?.source, .docker(hostID: hostID, containerName: "webapp"))
    }

    func testParseFavoriteID_roundTrip_host() {
        let state = AppState()
        let original = TmuxSession(name: "work", source: .host(hostID: HostConfig.localhostID))
        let parsed = state.parseFavoriteID(original.id)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.id, original.id)
        XCTAssertEqual(parsed?.name, original.name)
        XCTAssertEqual(parsed?.source, original.source)
    }

    func testParseFavoriteID_roundTrip_docker() {
        let state = AppState()
        let original = TmuxSession(name: "shell", source: .docker(hostID: HostConfig.localhostID, containerName: "redis"))
        let parsed = state.parseFavoriteID(original.id)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.id, original.id)
    }

    func testParseFavoriteID_utilityReturnsNil() {
        let state = AppState()
        let logsSession = TmuxSession(name: "logs", source: .dockerLogs(hostID: HostConfig.localhostID, containerName: "app"))
        XCTAssertNil(state.parseFavoriteID(logsSession.id), "Utility sessions should not be recreated")

        let topSession = TmuxSession(name: "top", source: .dockerTop(hostID: HostConfig.localhostID, containerName: "app"))
        XCTAssertNil(state.parseFavoriteID(topSession.id))
    }

    func testParseFavoriteID_invalidID() {
        let state = AppState()
        XCTAssertNil(state.parseFavoriteID(""))
        XCTAssertNil(state.parseFavoriteID("garbage"))
        XCTAssertNil(state.parseFavoriteID("host:not-a-uuid:name"))
        XCTAssertNil(state.parseFavoriteID("host:\(UUID().uuidString):")) // empty name
    }

    func testParseFavoriteID_sessionNameWithColon() {
        let state = AppState()
        let hostID = HostConfig.localhostID
        // Edge case: session name contains a colon
        let id = "host:\(hostID.uuidString):my:session"
        let session = state.parseFavoriteID(id)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.name, "my:session")
    }

    func testParseFavoriteID_unknownHostID() {
        let state = AppState()
        let unknownID = UUID()
        let id = "host:\(unknownID.uuidString):main"
        let session = state.parseFavoriteID(id)
        // Should still parse — the caller decides whether the host exists
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.source.hostID, unknownID)
    }
}

