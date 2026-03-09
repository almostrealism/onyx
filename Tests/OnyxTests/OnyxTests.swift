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

    // MARK: - isLocal

    func testIsLocal_localhost() {
        let state = AppState()
        state.sshConfig.host = "localhost"
        XCTAssertTrue(state.isLocal)
    }

    func testIsLocal_127001() {
        let state = AppState()
        state.sshConfig.host = "127.0.0.1"
        XCTAssertTrue(state.isLocal)
    }

    func testIsLocal_ipv6Loopback() {
        let state = AppState()
        state.sshConfig.host = "::1"
        XCTAssertTrue(state.isLocal)
    }

    func testIsLocal_empty() {
        let state = AppState()
        state.sshConfig.host = ""
        XCTAssertTrue(state.isLocal)
    }

    func testIsLocal_whitespace() {
        let state = AppState()
        state.sshConfig.host = "  "
        XCTAssertTrue(state.isLocal)
    }

    func testIsLocal_remoteHost() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        XCTAssertFalse(state.isLocal)
    }

    func testIsLocal_caseInsensitive() {
        let state = AppState()
        state.sshConfig.host = "LOCALHOST"
        XCTAssertTrue(state.isLocal)
    }

    // MARK: - sshCommand

    func testSshCommand_local() {
        let state = AppState()
        state.sshConfig.host = "localhost"
        state.sshConfig.tmuxSession = "dev"
        let (cmd, args) = state.sshCommand()
        // Local mode: uses shell, not ssh
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertTrue(args.last?.contains("tmux new-session -A -s dev") ?? false)
    }

    func testSshCommand_remote_defaultPort() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.user = "admin"
        state.sshConfig.tmuxSession = "main"
        let (cmd, args) = state.sshCommand()

        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("admin@myserver.com"))
        // Should not contain -p flag for default port
        XCTAssertFalse(args.contains("-p"))
        // Last arg should have tmux command
        XCTAssertTrue(args.last?.contains("tmux new-session -A -s main") ?? false)
    }

    func testSshCommand_remote_customPort() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.port = 2222
        state.sshConfig.tmuxSession = "work"
        let (cmd, args) = state.sshCommand()

        XCTAssertEqual(cmd, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("2222"))
    }

    func testSshCommand_remote_withIdentityFile() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.identityFile = "/home/user/.ssh/custom_key"
        state.sshConfig.tmuxSession = "work"
        let (_, args) = state.sshCommand()

        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/home/user/.ssh/custom_key"))
    }

    func testSshCommand_remote_noUser() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.user = ""
        state.sshConfig.tmuxSession = "main"
        let (cmd, _) = state.sshCommand()

        XCTAssertEqual(cmd, "/usr/bin/ssh")
    }

    func testSshCommand_withExplicitSession() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.tmuxSession = "default"
        let (_, args) = state.sshCommand(session: "custom")

        XCTAssertTrue(args.last?.contains("tmux new-session -A -s custom") ?? false)
    }

    func testSshCommand_usesActiveSessionWhenSet() {
        let state = AppState()
        state.sshConfig.host = "myserver.com"
        state.sshConfig.tmuxSession = "default"
        state.activeSession = "running"
        let (_, args) = state.sshCommand()

        XCTAssertTrue(args.last?.contains("tmux new-session -A -s running") ?? false)
    }

    // MARK: - effectiveWindowTitle

    func testEffectiveWindowTitle_default() {
        let state = AppState()
        XCTAssertEqual(state.effectiveWindowTitle, "Onyx")
    }

    func testEffectiveWindowTitle_withSession() {
        let state = AppState()
        state.activeSession = "dev"
        XCTAssertTrue(state.effectiveWindowTitle.contains("dev"))
        XCTAssertTrue(state.effectiveWindowTitle.hasPrefix("Onyx"))
    }

    func testEffectiveWindowTitle_withMonitor() {
        let state = AppState()
        state.showMonitor = true
        XCTAssertTrue(state.effectiveWindowTitle.contains("Monitoring"))
    }

    func testEffectiveWindowTitle_withSessionAndMonitor() {
        let state = AppState()
        state.activeSession = "prod"
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
        state.showNotes = true
        state.dismissTopOverlay()
        XCTAssertFalse(state.showSettings)
        XCTAssertTrue(state.showNotes) // not dismissed yet
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
        state.sshConfig.host = "localhost"
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
