import XCTest
@testable import OnyxCore
@testable import OnyxLib

/// Which client a call rides on the Mac (Settings → Hosts → SSH client).
final class EngineTransportTests: XCTestCase {

    private final class Recorder: RemoteTransport {
        let name: String
        var calls = 0
        init(_ name: String) { self.name = name }
        func execute(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval,
                     label: String) -> RemoteOutput {
            calls += 1
            return RemoteOutput(exit: 0, stdout: name, stderr: "", timedOut: false)
        }
        func start(_ invocation: RemoteInvocation, on host: HostConfig, timeout: TimeInterval, label: String,
                   onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) -> RemoteJob {
            fatalError("unused")
        }
        func upload(_ localPath: String, to remotePath: String, on host: HostConfig, recursive: Bool,
                    timeout: TimeInterval, label: String) -> RemoteOutput { execute(.command(""), on: host, timeout: 0, label: "") }
        func download(_ remotePath: String, to localPath: String, from host: HostConfig, recursive: Bool,
                      timeout: TimeInterval, label: String) -> RemoteOutput { execute(.command(""), on: host, timeout: 0, label: "") }
    }

    private let remote = HostConfig(label: "r", ssh: SSHConfig(host: "box.example"))

    func testOpenSSHCarriesEverythingByDefault() {
        let p = Recorder("openssh"), b = Recorder("built-in")
        let t = EngineTransport(process: p, builtIn: b, engine: { .openSSH })
        XCTAssertEqual(t.runCommand("x", on: remote, label: "t").stdout, "openssh")
        XCTAssertEqual(b.calls, 0)
    }

    func testBuiltInForSharedStateLeavesTheRestOnOpenSSH() {
        let p = Recorder("openssh"), b = Recorder("built-in")
        let t = EngineTransport(process: p, builtIn: b, engine: { .builtInForSharedState })
        XCTAssertEqual(t.runCommand("x", on: remote, label: "t").stdout, "openssh")
    }

    func testBuiltInForEverythingButLocalHosts() {
        let p = Recorder("openssh"), b = Recorder("built-in")
        var engine = SSHEngine.builtIn
        let t = EngineTransport(process: p, builtIn: b, engine: { engine })
        XCTAssertEqual(t.runCommand("x", on: remote, label: "t").stdout, "built-in")
        XCTAssertEqual(t.upload("/a", to: "b", on: remote, recursive: false, timeout: 1, label: "t").stdout, "built-in")
        XCTAssertEqual(t.runCommand("x", on: .localhost, label: "t").stdout, "openssh", "this Mac is a process")
        engine = .openSSH
        XCTAssertEqual(t.runCommand("x", on: remote, label: "t").stdout, "openssh", "switching back is immediate")
    }

    func testSyncFollowsEitherBuiltInChoice() {
        XCTAssertFalse(SSHEngine.openSSH.syncsBuiltIn)
        XCTAssertTrue(SSHEngine.builtInForSharedState.syncsBuiltIn)
        XCTAssertTrue(SSHEngine.builtIn.syncsBuiltIn)
    }
}
