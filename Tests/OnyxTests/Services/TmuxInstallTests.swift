import XCTest
import SwiftUI
import AppKit
@testable import OnyxCore
@testable import OnyxLib

/// A host without tmux: the probe, its parser, and the install command
/// each platform gets. The probe runs in the remote's own shell, so it is
/// also run here, for real, in each shell a host is likely to have.
final class TmuxInstallTests: XCTestCase {

    private let hostID = UUID()

    private func plan(_ probe: TmuxProbe) -> TmuxInstallPlan {
        TmuxInstall.plan(for: probe, hostID: hostID, hostLabel: "build")
    }

    // MARK: - Parsing

    func testParsesTheProbesLine() {
        let probe = TmuxInstall.parse("Welcome to Ubuntu\nONYX-TMUX|no|Linux|ubuntu|debian| apt-get snap|sudo\n")
        XCTAssertEqual(probe, TmuxProbe(present: false, system: "Linux", osID: "ubuntu",
                                        osLike: ["debian"], managers: ["apt-get"], privilege: .sudo))
    }

    /// Over a terminal the script is echoed, and the echo of its last line
    /// can come after the real answer. The echo is never the answer.
    func testIgnoresTheEchoOfTheScript() {
        let output = """
            ONYX-TMUX|yes|Linux|fedora||  dnf|root
            echo "ONYX-TMUX|$t|$(uname -s)|$os|$like|$m|$s"
            """
        XCTAssertEqual(TmuxInstall.parse(output)?.present, true)
        XCTAssertEqual(TmuxInstall.parse(output)?.managers, ["dnf"])
        XCTAssertNil(TmuxInstall.parse("echo \"ONYX-TMUX|$t|$(uname -s)|$os|$like|$m|$s\""))
    }

    func testNoAnswerIsNotAnAnswer() {
        XCTAssertNil(TmuxInstall.parse(""))
        XCTAssertNil(TmuxInstall.parse("zsh: event not found"))
        XCTAssertNil(TmuxInstall.parse("ONYX-TMUX|maybe|Linux||||root"))
    }

    // MARK: - Plans

    func testUbuntuWithSudoUsesAptUnderSudo() {
        let p = plan(TmuxProbe(present: false, system: "Linux", osID: "ubuntu",
                               managers: ["apt-get"], privilege: .sudo))
        XCTAssertEqual(p.manager, "apt-get")
        XCTAssertEqual(p.command, "sudo apt-get update && sudo apt-get install -y tmux")
        XCTAssertEqual(p.passwordPrompt, "sudo")
        XCTAssertTrue(p.advice.contains("password"))
    }

    func testRootNeedsNoSudo() {
        let p = plan(TmuxProbe(present: false, system: "Linux", osID: "alpine",
                               managers: ["apk"], privilege: .root))
        XCTAssertEqual(p.command, "apk add tmux")
        XCTAssertNil(p.passwordPrompt)
    }

    func testWithoutSudoItAsksSuAndSaysWhosePassword() {
        let p = plan(TmuxProbe(present: false, system: "Linux", osID: "debian",
                               managers: ["apt-get"], privilege: .none))
        XCTAssertEqual(p.command, "su -c \"apt-get update && apt-get install -y tmux\"")
        XCTAssertEqual(p.passwordPrompt, "su")
        XCTAssertTrue(p.advice.contains("root's password"))
    }

    func testTheDistrosManagerBeatsLinuxbrew() {
        let p = plan(TmuxProbe(present: false, system: "Linux", managers: ["dnf", "brew"], privilege: .sudo))
        XCTAssertEqual(p.manager, "dnf")
        XCTAssertEqual(p.command, "sudo dnf install -y tmux")
    }

    /// Homebrew refuses to run as root, so never sudo it — even when the
    /// probe found sudo or root.
    func testAMacUsesHomebrewWithoutSudo() {
        let p = plan(TmuxProbe(present: false, system: "Darwin", managers: ["brew", "port"], privilege: .sudo))
        XCTAssertEqual(p.command, "brew install tmux")
        XCTAssertNil(p.passwordPrompt)
    }

    func testAMacWithoutHomebrewIsToldWhereToGetIt() {
        let p = plan(TmuxProbe(present: false, system: "Darwin", managers: [], privilege: .sudo))
        XCTAssertNil(p.command)
        XCTAssertEqual(p.helpURL, "https://brew.sh")
        XCTAssertTrue(p.advice.contains("brew install tmux"))
    }

    func testAnUnknownSystemGetsAdviceNotACommand() {
        let p = plan(TmuxProbe(present: false, system: "SunOS", managers: [], privilege: .root))
        XCTAssertNil(p.command)
        XCTAssertEqual(p.helpURL, TmuxInstall.helpURL)
        XCTAssertTrue(p.message.contains("build doesn't have tmux"))
    }

    func testEveryKnownManagerHasSteps() {
        for manager in TmuxInstall.knownManagers {
            XCTAssertFalse(TmuxInstall.installSteps(manager).isEmpty, manager)
        }
    }

    // MARK: - Scripts

    /// The install script travels inside `$SHELL -lc '…'`: one single
    /// quote anywhere ends it early. And `!` is zsh history expansion.
    func testTheInstallScriptSurvivesTheWrapper() {
        for manager in TmuxInstall.knownManagers {
            for privilege in [TmuxProbe.Privilege.root, .sudo, .none] {
                let system = manager == "brew" || manager == "port" ? "Darwin" : "Linux"
                let p = plan(TmuxProbe(present: false, system: system, managers: [manager], privilege: privilege))
                guard let script = TmuxInstall.terminalScript(p) else { continue }
                XCTAssertFalse(script.contains("'"), "\(manager)/\(privilege): \(script)")
                XCTAssertFalse(script.contains("!"), "\(manager)/\(privilege): \(script)")
            }
        }
    }

    func testTheProbeObeysTheRemoteScriptRules() {
        XCTAssertFalse(TmuxInstall.probeScript.contains("!"), "zsh history expansion eats the line")
        XCTAssertFalse(TmuxInstall.probeScript.contains("*"), "an unmatched glob is fatal in zsh")
    }

    /// The probe really runs, in the shells a host is likely to log in
    /// with, and the answer agrees with the shell's own view of tmux.
    func testTheProbeRunsInEachShell() throws {
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let output = try run(shell, ["-c", TmuxInstall.probeScript])
            let probe = try XCTUnwrap(TmuxInstall.parse(output), "\(shell) gave: \(output)")
            let expected = try run(shell, ["-c", "export \(RemoteWire.extraPath); command -v tmux >/dev/null 2>&1 && echo yes || echo no"])
            XCTAssertEqual(probe.present, expected.contains("yes"), shell)
            XCTAssertEqual(probe.system, "Darwin", shell)
            XCTAssertNotEqual(probe.privilege, .root, shell)
        }
    }

    /// With nothing on the PATH but the basics, tmux isn't found — the
    /// answer a host without it gives.
    func testTheProbeSaysNoWhenTmuxIsntThere() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-no-tmux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        // The probe ADDS Homebrew's and /usr/local's bin to the PATH, so
        // swap those for an empty directory to stand in for a bare host.
        let script = TmuxInstall.probeScript.replacingOccurrences(of: RemoteWire.extraPath,
                                                                  with: "PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        let output = try run("/bin/sh", ["-c", script])
        XCTAssertEqual(TmuxInstall.parse(output)?.present, false, output)
    }

    private func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - The terminal that installs it

    func testTheInstallTerminalRidesTheHostLikeASession() throws {
        let state = AppState()
        let host = HostConfig(label: "server", ssh: SSHConfig(host: "myserver.com", user: "admin", tmuxSession: "main"))
        let p = TmuxInstall.plan(for: TmuxProbe(present: false, system: "Linux", managers: ["apt-get"], privilege: .sudo),
                                 hostID: host.id, hostLabel: host.label)
        let (cmd, args) = try XCTUnwrap(state.tmuxInstallCommand(host: host, plan: p))
        let (sessionCmd, sessionArgs) = state.sshCommand(host: host, sessionName: "main")
        XCTAssertEqual(cmd, sessionCmd)
        XCTAssertTrue(args.contains("-t"), "sudo needs a terminal to ask for the password")
        XCTAssertTrue(args.contains("admin@myserver.com"))
        // Same connection options as a session: it rides the host's pair.
        let options = { (a: [String]) in a.prefix { $0 != "-t" && $0 != "admin@myserver.com" } }
        XCTAssertTrue(Set(options(sessionArgs)).isSuperset(of: Set(options(args))))
        let remote = try XCTUnwrap(args.last)
        XCTAssertTrue(remote.hasPrefix("exec $SHELL -lc '"))
        XCTAssertTrue(remote.contains("sudo apt-get install -y tmux"))
        XCTAssertEqual(remote.filter { $0 == "'" }.count, 2, "only the wrapper's own quotes")
    }

    func testOnThisMacItIsALocalShell() throws {
        let state = AppState()
        let p = TmuxInstall.plan(for: TmuxProbe(present: false, system: "Darwin", managers: ["brew"]),
                                 hostID: HostConfig.localhost.id, hostLabel: "This Mac")
        let (cmd, args) = try XCTUnwrap(state.tmuxInstallCommand(host: .localhost, plan: p))
        XCTAssertFalse(cmd.contains("ssh"))
        XCTAssertEqual(args.first, "-lc")
        XCTAssertTrue(args.last?.contains("brew install tmux") ?? false)
    }

    func testNoCommandMeansNoTerminal() {
        let state = AppState()
        let p = TmuxInstall.plan(for: TmuxProbe(present: false, system: "SunOS"),
                                 hostID: HostConfig.localhost.id, hostLabel: "x")
        XCTAssertNil(state.tmuxInstallCommand(host: .localhost, plan: p))
    }

    // MARK: - The state

    func testTheStateGatesInputAndExplains() {
        let p = plan(TmuxProbe(present: false, system: "Linux", managers: ["apt-get"], privilege: .sudo))
        let state = SessionConnectionState.tmuxMissing(p)
        XCTAssertTrue(state.shouldGateInput)
        XCTAssertTrue(state.showErrorOverlay)
        XCTAssertFalse(state.showReconnectingOverlay)
        XCTAssertEqual(state.tmuxInstallPlan, p)
        XCTAssertEqual(state.errorMessage, p.message)
    }
}

/// The install terminal's script, run for real inside the wrapper the
/// terminal uses (`$SHELL -lc '…'`), with a stand-in package manager —
/// one that installs a stand-in tmux, and one that fails.
final class TmuxInstallScriptRunTests: XCTestCase {

    private var bin: URL!

    override func setUpWithError() throws {
        bin = FileManager.default.temporaryDirectory.appendingPathComponent("onyx-fake-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bin)
    }

    private func fakeBrew(installs: Bool) throws {
        let body = installs
            ? "#!/bin/sh\nprintf '#!/bin/sh\\n' > \"\(bin.path)/tmux\"; chmod +x \"\(bin.path)/tmux\"; echo installed\n"
            : "#!/bin/sh\necho 'Error: no bottle' >&2; exit 1\n"
        let brew = bin.appendingPathComponent("brew")
        try body.write(to: brew, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
    }

    /// Runs the script as the terminal would, with only our directory and
    /// the system's on the PATH (not Homebrew's, where a real tmux lives).
    private func runInstall() throws -> (status: Int32, output: String) {
        let plan = TmuxInstall.plan(for: TmuxProbe(present: false, system: "Darwin", managers: ["brew"]),
                                    hostID: UUID(), hostLabel: "test")
        let script = try XCTUnwrap(TmuxInstall.terminalScript(plan))
            .replacingOccurrences(of: RemoteWire.extraPath, with: "PATH=\(bin.path):/usr/bin:/bin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "exec /bin/zsh -lc '\(script)'"]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": bin.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice   // the failure's "Press Return"
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testASuccessfulInstallExitsZero() throws {
        try fakeBrew(installs: true)
        let (status, output) = try runInstall()
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.contains("Installing tmux with brew"), output)
        XCTAssertTrue(output.contains("tmux is installed"), output)
    }

    func testAFailedInstallSaysSoAndExitsNonZero() throws {
        try fakeBrew(installs: false)
        let (status, output) = try runInstall()
        XCTAssertEqual(status, 1, output)
        XCTAssertTrue(output.contains("tmux is still not installed"), output)
    }
}

/// The overlay a host without tmux gets, rendered for each kind of plan:
/// sudo, su, and one Onyx can't carry out. Set ONYX_OVERLAY_RENDER_DIR
/// to look at them.
@MainActor
final class TmuxOverlayRenderTests: XCTestCase {

    func testTheOverlayRendersForEachKindOfPlan() throws {
        let probes: [(String, TmuxProbe)] = [
            ("sudo", TmuxProbe(present: false, system: "Linux", osID: "ubuntu", managers: ["apt-get"], privilege: .sudo)),
            ("su", TmuxProbe(present: false, system: "Linux", osID: "debian", managers: ["apt-get"], privilege: .none)),
            ("nobrew", TmuxProbe(present: false, system: "Darwin", managers: [], privilege: .sudo)),
        ]
        let out = ProcessInfo.processInfo.environment["ONYX_OVERLAY_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        for (name, probe) in probes {
            let state = AppState()
            let host = HostConfig(label: "gpu-01", ssh: SSHConfig(host: "gpu-01.lan", user: "me", tmuxSession: "main"))
            state.hosts = [host]
            let session = TmuxSession(name: "main", source: .host(hostID: host.id))
            state.activeSession = session
            var plan = TmuxInstall.plan(for: probe, hostID: host.id, hostLabel: host.label)
            plan.lastAttemptFailed = name == "su"
            state.sessionConnectionStates[session.id] = .tmuxMissing(plan)
            XCTAssertTrue(state.activeSessionConnectionState.showErrorOverlay)

            let view = ConnectionErrorOverlay(appState: state)
                .frame(width: 760, height: 560)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, name)
            if let out, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("tmux-overlay-\(name).png"))
            }
        }
    }
}
