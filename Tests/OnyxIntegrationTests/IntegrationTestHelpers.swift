import Foundation
import XCTest

/// Shared utilities for OnyxIntegrationTests.
enum IntegrationTestHelpers {

    /// Locate the built OnyxMCP executable. Searches:
    ///   1. $BUILT_PRODUCTS_DIR (Xcode env var)
    ///   2. $ONYX_MCP_BIN (manual override)
    ///   3. Common SwiftPM build output paths under the package root
    static func locateOnyxMCPBinary() -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        var candidates: [URL] = []

        if let built = env["BUILT_PRODUCTS_DIR"] {
            candidates.append(URL(fileURLWithPath: built).appendingPathComponent("OnyxMCP"))
        }
        if let override = env["ONYX_MCP_BIN"] {
            candidates.append(URL(fileURLWithPath: override))
        }

        // Walk up from this file location to the package root, then look in .build/
        let packageRoot = packageRootURL()
        let buildDir = packageRoot.appendingPathComponent(".build")
        let archs = ["debug", "release",
                     "arm64-apple-macosx/debug", "arm64-apple-macosx/release",
                     "x86_64-apple-macosx/debug", "x86_64-apple-macosx/release"]
        for arch in archs {
            candidates.append(buildDir.appendingPathComponent(arch).appendingPathComponent("OnyxMCP"))
        }

        for c in candidates where fm.isExecutableFile(atPath: c.path) {
            return c
        }
        return nil
    }

    /// Throw an XCTSkip if the OnyxMCP binary can't be found.
    static func requireOnyxMCPBinary() throws -> URL {
        guard let url = locateOnyxMCPBinary() else {
            throw XCTSkip("OnyxMCP binary not found. Run `swift build --product OnyxMCP` first.")
        }
        return url
    }

    /// Throw an XCTSkip if `ssh` is not on PATH.
    static func requireSSH() throws -> URL {
        let candidates = ["/usr/bin/ssh", "/usr/local/bin/ssh", "/opt/homebrew/bin/ssh"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Try `which`
        let p = Process()
        p.launchPath = "/usr/bin/which"
        p.arguments = ["ssh"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
            return URL(fileURLWithPath: s)
        }
        throw XCTSkip("ssh not found on PATH")
    }

    /// Walk up from this source file's location to find the SwiftPM package root.
    static func packageRootURL() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: fm.currentDirectoryPath)
    }

    /// Run a Process with optional stdin payload, returning (stdoutString, stderrString, exitCode).
    @discardableResult
    static func runProcess(
        _ executable: URL,
        arguments: [String] = [],
        stdin: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5
    ) -> (stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment = environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do { try process.run() } catch {
            return ("", "spawn failed: \(error)", -1, false)
        }

        if let stdin = stdin, let data = stdin.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.waitUntilExit()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus,
            timedOut
        )
    }
}

/// A thin wrapper around an OnyxMCP subprocess speaking newline-delimited JSON-RPC on stdio.
final class MCPClient {
    let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var buffer = Data()

    init(binary: URL, environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = binary
        if let environment = environment { process.environment = environment }
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stderr = errPipe.fileHandleForReading
    }

    /// Send a raw JSON string as one newline-delimited message.
    func sendRaw(_ json: String) throws {
        var line = json
        if !line.hasSuffix("\n") { line += "\n" }
        guard let data = line.data(using: .utf8) else {
            throw NSError(domain: "MCPClient", code: 1)
        }
        try stdin.write(contentsOf: data)
    }

    /// Read one newline-delimited line from stdout, blocking up to `timeout` seconds.
    /// Returns nil if no data is received before the timeout (e.g. for a notification).
    func receiveLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                return String(data: lineData, encoding: .utf8)
            }
            if Date() > deadline { return nil }
            // Non-blocking-ish read with short sleep
            let chunk = stdout.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
                if !process.isRunning && stdout.availableData.isEmpty && buffer.isEmpty {
                    return nil
                }
            } else {
                buffer.append(chunk)
            }
        }
    }

    func closeStdin() {
        try? stdin.close()
    }

    func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline { return nil }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return process.terminationStatus
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    deinit { terminate() }
}
