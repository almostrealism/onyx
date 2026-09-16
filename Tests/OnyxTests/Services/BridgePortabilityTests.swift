import XCTest

/// OnyxMCP builds for Linux in CI and runs on hosts that are usually not
/// Macs — but the tests, and the machine anyone writes it on, are macOS.
/// Two traps have already cost a CI round trip each, and both are visible
/// in the source without a Linux toolchain.
final class BridgePortabilityTests: XCTestCase {

    private var bridgeSources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("Sources/OnyxMCP")
        return (try? FileManager.default.contentsOfDirectory(at: root,
                                                             includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swift" } ?? []
    }

    /// Foundation re-exports Darwin on a Mac, so a file calling flock() or
    /// socket() compiles there with no platform import at all — and fails
    /// on Linux, where it does not.
    func testEveryFileUsingPOSIXImportsGlibcForLinux() throws {
        let posix = ["socket(", "connect(", "flock(", "setsockopt(", "inet_addr(", "usleep("]
        for file in bridgeSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard posix.contains(where: { text.contains($0) }) else { continue }
            XCTAssertTrue(text.contains("import Glibc"),
                          """
                          \(file.lastPathComponent) calls POSIX directly but never imports \
                          Glibc. It builds on macOS because Foundation re-exports Darwin, \
                          and fails on Linux, where it does not.
                          """)
        }
    }

    /// SOCK_STREAM is an Int32 in Darwin's headers and a `__socket_type`
    /// enum in Glibc's, so the literal that compiles on a Mac is a type
    /// error on Linux.
    func testTheSocketTypeIsSpelledPortably() throws {
        for file in bridgeSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n")
            where line.contains("socket(") && line.contains("SOCK_STREAM") {
                XCTFail("""
                    \(file.lastPathComponent) passes SOCK_STREAM straight to socket(): \
                    that is an Int32 on Darwin and an enum on Glibc. Use the platform \
                    constant instead — `\(line.trimmingCharacters(in: .whitespaces))`
                    """)
            }
        }
    }
}
