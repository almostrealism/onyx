import XCTest
@testable import OnyxLib

/// Choosing what to install and where. These decisions happen before any
/// SSH, which is what makes them testable — and worth testing, because
/// getting them wrong means uploading a binary that can't run, or writing
/// over somebody's Claude configuration.
final class MCPPlatformTests: XCTestCase {

    // MARK: - Reading uname

    /// The same silicon answers `arm64` on macOS and `aarch64` on Linux.
    /// Two spellings, one artifact.
    func testArmIsRecognisedUnderEitherName() {
        XCTAssertEqual(RemotePlatform.parse(uname: "Darwin", machine: "arm64"),
                       RemotePlatform(os: .macOS, arch: "arm64"))
        XCTAssertEqual(RemotePlatform.parse(uname: "Linux", machine: "aarch64"),
                       RemotePlatform(os: .linux, arch: "arm64"))
    }

    func testIntelSpellingsAllNormalise() {
        for machine in ["x86_64", "amd64", "x64"] {
            XCTAssertEqual(RemotePlatform.parse(uname: "Linux", machine: machine)?.arch,
                           "x86_64", "\(machine) should normalise")
        }
    }

    func testUnameOutputIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(RemotePlatform.parse(uname: " linux \n", machine: " AARCH64 \n"),
                       RemotePlatform(os: .linux, arch: "arm64"))
    }

    /// Better to say "I don't recognise this" than to upload an x86
    /// binary to a RISC-V box and let it fail as "cannot execute".
    func testUnknownPlatformsAreRefusedRatherThanGuessed() {
        XCTAssertNil(RemotePlatform.parse(uname: "FreeBSD", machine: "x86_64"))
        XCTAssertNil(RemotePlatform.parse(uname: "Linux", machine: "riscv64"))
        XCTAssertNil(RemotePlatform.parse(uname: "", machine: ""))
    }

    // MARK: - Artifact names

    func testArtifactNamesMatchWhatIsShipped() {
        // These strings are the contract between package.sh, the CI
        // workflow, and the installer. If one side changes, this fails.
        XCTAssertEqual(RemotePlatform(os: .macOS, arch: "arm64").artifactName,
                       "OnyxMCP-macos-arm64")
        XCTAssertEqual(RemotePlatform(os: .linux, arch: "arm64").artifactName,
                       "OnyxMCP-linux-arm64")
        XCTAssertEqual(RemotePlatform(os: .linux, arch: "x86_64").artifactName,
                       "OnyxMCP-linux-x86_64")
    }

    // MARK: - Install location

    /// On a Mac the install should land somewhere every account can run
    /// it from — the agent being wired up may not run as you.
    func testMacPrefersSharedAndLinuxUsesHome() {
        XCTAssertEqual(MCPInstall.defaultBase(for: RemotePlatform(os: .linux, arch: "arm64")),
                       "$HOME")
        XCTAssertEqual(MCPInstall.defaultBase(for: RemotePlatform(os: .macOS, arch: "arm64")),
                       "${SHARED_OR_HOME}")
    }

    /// /Users/Shared exists on every Mac but a managed one can make it
    /// read-only, so presence alone isn't enough to install there.
    func testSharedIsOnlyUsedWhenItIsAlsoWritable() {
        XCTAssertTrue(MCPInstall.sharedOrHomeScript.contains("-w /Users/Shared"))
        XCTAssertTrue(MCPInstall.sharedOrHomeScript.contains("SHARED_OR_HOME=\"$HOME\""))
    }

    func testBinaryPathJoinsWithoutDoubleSlashes() {
        XCTAssertEqual(MCPInstall.binaryPath(base: "/Users/Shared"),
                       "/Users/Shared/.onyx/bin/OnyxMCP")
        XCTAssertEqual(MCPInstall.binaryPath(base: "/Users/Shared/"),
                       "/Users/Shared/.onyx/bin/OnyxMCP")
    }

    func testHookCommandPointsAtTheInstalledBinary() {
        XCTAssertEqual(MCPInstall.hookCommand(binaryPath: "/opt/.onyx/bin/OnyxMCP"),
                       "/opt/.onyx/bin/OnyxMCP --hook")
    }
}

/// Reading the detection script's reply.
final class MCPStatusParsingTests: XCTestCase {

    private func out(_ s: String) -> MCPHostStatus { MCPInstaller.parseStatus(s) }

    func testAWorkingBridgeReportsItsVersion() {
        let s = out("""
        ---UNAME---
        Linux
        aarch64
        ---BASE---
        /home/me
        ---BIN---
        OnyxMCP 0.16
        """)
        XCTAssertEqual(s.state, .installed(version: "0.16"))
        XCTAssertEqual(s.path, "/home/me/.onyx/bin/OnyxMCP")
        XCTAssertTrue(s.isWorking)
    }

    func testAnAbsentBridgeIsNotInstalledRatherThanBroken() {
        let s = out("---UNAME---\nDarwin\narm64\n---BASE---\n/Users/Shared\n---BIN---\nABSENT")
        XCTAssertEqual(s.state, .notInstalled)
        XCTAssertEqual(s.path, "/Users/Shared/.onyx/bin/OnyxMCP")
    }

    /// A binary that's present and failing must not read as "not
    /// installed" — that sends someone to install what's already there.
    func testAFailingBridgeReportsWhatItSaid() {
        let s = out("""
        ---UNAME---
        Linux
        x86_64
        ---BASE---
        /home/me
        ---BIN---
        bash: line 1: /home/me/.onyx/bin/OnyxMCP: cannot execute binary file
        """)
        guard case .broken(let why) = s.state else {
            return XCTFail("expected broken, got \(s.state)")
        }
        XCTAssertTrue(why.contains("cannot execute"))
    }

    /// An interactive remote shell echoes the script back interleaved
    /// with its output, so the FIRST marker in the stream is often the
    /// echo of the line rather than its result. Every section is read
    /// from the last occurrence — this has broken git, docker and stats
    /// parsing before.
    func testEchoedScriptDoesNotShadowTheRealAnswer() {
        let s = out("""
        $ echo "---UNAME---"; uname -s; uname -m
        ---UNAME---
        Linux
        aarch64
        ---BASE---
        /home/me
        $ echo "---BIN---"
        ---BIN---
        OnyxMCP 0.16
        """)
        XCTAssertEqual(s.state, .installed(version: "0.16"))
    }

    func testUnreadableOutputIsUnknownNotAFalseNegative() {
        // A host that answered with nothing usable must not be reported
        // as "not installed" — we don't know that.
        XCTAssertEqual(out("").state, .unknown)
        XCTAssertEqual(out("zsh: event not found").state, .unknown)
    }
}
