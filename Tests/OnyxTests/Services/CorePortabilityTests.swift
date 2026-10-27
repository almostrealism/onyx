import XCTest

/// OnyxCore — and OnyxUI, OnyxSSH and OnyxToday, which build on it for
/// the iOS apps — build for iOS as well as macOS (docs/ios-plan.md). CI proves
/// it by building the core for the iOS simulator, but nobody runs that
/// before committing — and a Mac compiles an AppKit import, or a
/// `Process`, without a word. These catch both in `swift test`.
final class CorePortabilityTests: XCTestCase {

    static let portableTargets = ["OnyxCore", "OnyxUI", "OnyxSSH", "OnyxToday"]
    /// The iPad's target: UIKit and SwiftTerm are its job, but never
    /// AppKit or a process.
    static let padTarget = "OnyxPad"

    private var coreSources: [URL] { sources(in: Self.portableTargets) }

    private func sources(in targets: [String]) -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // OnyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        return targets.flatMap { target -> [URL] in
            let walker = FileManager.default.enumerator(at: repo.appendingPathComponent("Sources/\(target)"),
                                                        includingPropertiesForKeys: nil)
            return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
    }

    func testTheIPadTargetUsesNoMacOnlyAPI() throws {
        let files = sources(in: [Self.padTarget])
        XCTAssertGreaterThan(files.count, 2)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("import AppKit"), "\(file.lastPathComponent) imports AppKit")
            XCTAssertFalse(text.contains("import OnyxLib"), "\(file.lastPathComponent) imports the Mac app")
            XCTAssertFalse(text.contains("Process()"), "\(file.lastPathComponent) launches a process")
        }
    }

    func testTheCoreIsFound() {
        XCTAssertGreaterThan(coreSources.count, 50, "the scan must see the core, or it proves nothing")
    }

    /// Platform UI frameworks belong in the platform layers. SwiftTerm and
    /// the AppKit shims are Mac-only here too: the iPad drives SwiftTerm's
    /// UIKit view from its own layer.
    func testTheCoreImportsNoPlatformUI() throws {
        let banned = ["AppKit", "UIKit", "SwiftTerm", "OnyxAppKitShims", "WebKit", "SceneKit"]
        for file in coreSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.first == "import", words.count == 2,
                      banned.contains(String(words[1])) else { continue }
                XCTFail("""
                    \(file.lastPathComponent) imports \(words[1]), which the portable targets can't: \
                    they build for iOS. Put the platform half in OnyxLib (see Palette+AppKit.swift).
                    """)
            }
        }
    }

    /// iOS can't launch processes. Remote work runs through ssh processes
    /// on the Mac today (SSHProcess, RemoteExec), which stay in OnyxLib
    /// until the transport seam of phase 1.
    func testTheCoreLaunchesNoProcesses() throws {
        // `Process()` or a `: Process` annotation; ProcessInfo is fine.
        let process = try NSRegularExpression(pattern: #"\bProcess\(\)|:\s*Process\b(?!Info)"#)
        for file in coreSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let code = line.components(separatedBy: "//").first ?? ""
                let range = NSRange(code.startIndex..., in: code)
                guard process.firstMatch(in: code, range: range) != nil else { continue }
                XCTFail("""
                    \(file.lastPathComponent) uses Process, which doesn't exist on iOS: \
                    `\(line.trimmingCharacters(in: .whitespaces))`
                    """)
            }
        }
    }
}
