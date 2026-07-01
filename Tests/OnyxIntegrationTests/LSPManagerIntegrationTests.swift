import XCTest
@testable import OnyxLib

/// End-to-end test of the code-navigation stack (LSPManager → LSPSession →
/// jdtls) with NO UI. Runs jdtls locally against the bundled sample project
/// and asserts real semantic results come back.
///
/// Gated: skips unless jdtls is installed at ~/.onyx/jdtls and the sample
/// project is present. Install jdtls with:
///   mkdir -p ~/.onyx/jdtls && curl -fsSL \
///     https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz \
///     | tar xz -C ~/.onyx/jdtls
@MainActor
final class LSPManagerIntegrationTests: XCTestCase {

    private var sampleRoot: String {
        // `swift test` runs with the package root as cwd.
        FileManager.default.currentDirectoryPath + "/spike/sample-java"
    }

    private func requireEnvironment() throws {
        let fm = FileManager.default
        let jdtls = (NSHomeDirectory() as NSString).appendingPathComponent(".onyx/jdtls/bin/jdtls")
        guard fm.fileExists(atPath: jdtls) else {
            throw XCTSkip("jdtls not installed at ~/.onyx/jdtls — see file header")
        }
        guard fm.fileExists(atPath: sampleRoot + "/pom.xml") else {
            throw XCTSkip("sample project not found at \(sampleRoot)")
        }
    }

    func test_implementation_findsInterfaceImplementors() async throws {
        try requireEnvironment()

        let appState = AppState()
        appState.addHost(.localhost)   // so activeHost matches the host we query
        let shape = sampleRoot + "/src/main/java/com/onyx/spike/Shape.java"
        // `public interface Shape {` — the token "Shape" starts at UTF-16 col 17.
        await appState.lsp.navigate(.implementation, filePath: shape, line: 4, character: 17,
                                    host: .localhost)

        guard case let .results(kind, _, groups) = appState.lsp.state else {
            XCTFail("expected results, got \(appState.lsp.state)"); return
        }
        XCTAssertEqual(kind, .implementation)
        let files = Set(groups.map(\.fileName))
        // AbstractShape, Circle, Rectangle, Square all implement Shape.
        XCTAssertTrue(files.contains("Circle.java"), "implementors: \(files)")
        XCTAssertTrue(files.contains("Rectangle.java"), "implementors: \(files)")
        XCTAssertTrue(files.contains("Square.java"), "implementors: \(files)")
        XCTAssertGreaterThanOrEqual(groups.count, 3)

        appState.lsp.shutdownAll()
    }

    /// Exercises the REMOTE path (remoteLSPCommand ssh launch + remoteScript
    /// workspace resolution) — the production transport. Gated on env pointing
    /// at a reachable ssh host with jdtls installed, e.g. the loopback sshd:
    ///   ONYX_LSP_SSH_HOST=127.0.0.1 ONYX_LSP_SSH_USER=$USER \
    ///   ONYX_LSP_SSH_PORT=2222 ONYX_LSP_SSH_IDENTITY=~/.ssh/onyx_spike \
    ///   swift test --filter test_implementation_overSSH
    func test_implementation_overSSH() async throws {
        try requireEnvironment()
        let env = ProcessInfo.processInfo.environment
        guard let sshHost = env["ONYX_LSP_SSH_HOST"] else {
            throw XCTSkip("set ONYX_LSP_SSH_HOST (+ USER/PORT/IDENTITY) to run the SSH path")
        }
        var host = HostConfig.localhost
        host.id = UUID()                 // a real (non-local) host
        host.label = "loopback"
        host.ssh.host = sshHost
        host.ssh.user = env["ONYX_LSP_SSH_USER"] ?? NSUserName()
        host.ssh.port = Int(env["ONYX_LSP_SSH_PORT"] ?? "22") ?? 22
        host.ssh.identityFile = (env["ONYX_LSP_SSH_IDENTITY"] ?? "") as String

        let appState = AppState()
        appState.addHost(host)

        let shape = sampleRoot + "/src/main/java/com/onyx/spike/Shape.java"
        await appState.lsp.navigate(.implementation, filePath: shape, line: 4, character: 17,
                                    host: host)

        guard case let .results(_, _, groups) = appState.lsp.state else {
            XCTFail("expected results over SSH, got \(appState.lsp.state)"); return
        }
        let files = Set(groups.map(\.fileName))
        XCTAssertTrue(files.contains("Circle.java"), "implementors over SSH: \(files)")
        appState.lsp.shutdownAll()
    }

    func test_callers_findsIncomingCalls() async throws {
        try requireEnvironment()
        let appState = AppState()
        appState.addHost(.localhost)
        let shape = sampleRoot + "/src/main/java/com/onyx/spike/Shape.java"
        // area() is declared at line 6; Main.main and describe() call it.
        await appState.lsp.navigate(.callers, filePath: shape, line: 6, character: 11,
                                    host: .localhost)
        guard case let .results(_, _, groups) = appState.lsp.state else {
            XCTFail("expected caller results, got \(appState.lsp.state)"); return
        }
        let files = Set(groups.map(\.fileName))
        XCTAssertTrue(files.contains("Main.java") || files.contains("Shape.java"),
                      "callers of area(): \(files)")
        appState.lsp.shutdownAll()
    }

    func test_missingJDTLS_diagnosesAndOffersInstall() async throws {
        // Java 21 + python3 present locally, but point jdtls at a bogus path:
        // the manager should fail fast, run preflight, and offer to install.
        let fm = FileManager.default
        guard fm.fileExists(atPath: sampleRoot + "/pom.xml") else {
            throw XCTSkip("sample project not found")
        }
        let appState = AppState()
        var host = HostConfig.localhost
        host.codeIntel.jdtlsPath = "/tmp/onyx-nonexistent/bin/jdtls"
        appState.addHost(host)

        let shape = sampleRoot + "/src/main/java/com/onyx/spike/Shape.java"
        await appState.lsp.navigate(.implementation, filePath: shape, line: 4, character: 17,
                                    host: host)

        guard case let .setupRequired(_, canInstall) = appState.lsp.state else {
            XCTFail("expected setupRequired, got \(appState.lsp.state)"); return
        }
        XCTAssertTrue(canInstall, "java21 + python3 present → install should be offered")
        appState.lsp.shutdownAll()
    }

    func test_subtypes_findsSubclasses() async throws {
        try requireEnvironment()

        let appState = AppState()
        appState.addHost(.localhost)
        let base = sampleRoot + "/src/main/java/com/onyx/spike/AbstractShape.java"
        // `public abstract class AbstractShape ...` — "AbstractShape" at col 22.
        await appState.lsp.navigate(.subtypes, filePath: base, line: 4, character: 22,
                                    host: .localhost)

        guard case let .results(_, _, groups) = appState.lsp.state else {
            XCTFail("expected results, got \(appState.lsp.state)"); return
        }
        let files = Set(groups.map(\.fileName))
        XCTAssertTrue(files.contains("Circle.java"), "subtypes: \(files)")
        XCTAssertTrue(files.contains("Square.java"), "subtypes: \(files)")

        appState.lsp.shutdownAll()
    }
}
