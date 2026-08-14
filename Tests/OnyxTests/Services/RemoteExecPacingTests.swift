import XCTest
@testable import OnyxLib

/// `ssh -tt` puts a terminal on the far end, and a terminal's input buffer
/// is about 1KB. Writing a script faster than the remote shell reads it
/// overflows that buffer and the remainder is DISCARDED — the shell then
/// waits forever for the rest of a line, and the poll dies at the watchdog
/// with nothing to show but the host's login banner.
final class RemoteExecPacingTests: XCTestCase {

    func testChunkFitsInsideATerminalInputBuffer() {
        // macOS MAX_CANON is 1024. Anything at or above it can be dropped
        // in a single gulp, whatever the pause between writes.
        XCTAssertLessThan(RemoteExec.stdinChunk, 1024)
        XCTAssertGreaterThan(RemoteExec.stdinPause, 0,
                             "a zero pause is not pacing — it's the bug")
    }

    func testEveryByteArrivesInOrder() {
        // Pacing must not cost us data: the whole point is that the remote
        // shell sees the complete script.
        let script = (0..<400).map { "echo line-\($0)" }.joined(separator: "\n")
        let data = Data(script.utf8)
        let pipe = Pipe()

        var received = Data()
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            received = pipe.fileHandleForReading.readDataToEndOfFile()
            done.fulfill()
        }

        RemoteExec.writePaced(data, to: pipe.fileHandleForWriting)
        try? pipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(received, data, "paced delivery must be lossless and ordered")
        XCTAssertEqual(String(data: received, encoding: .utf8), script)
    }

    func testDeliveryIsActuallySpreadOverTime() {
        // Guards against someone "optimising" the pause away: a payload of
        // several chunks must take at least the pauses between them.
        let data = Data(String(repeating: "x", count: RemoteExec.stdinChunk * 4).utf8)
        let pipe = Pipe()
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            done.fulfill()
        }

        let start = Date()
        RemoteExec.writePaced(data, to: pipe.fileHandleForWriting)
        let elapsed = Date().timeIntervalSince(start)
        try? pipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 10)

        XCTAssertGreaterThanOrEqual(elapsed, RemoteExec.stdinPause * 3 * 0.9,
                                    "4 chunks means 3 pauses")
    }

    func testSmallPayloadIsNotDelayed() {
        // One chunk needs no pause at all — a short script must stay fast.
        let data = Data(String(repeating: "y", count: RemoteExec.stdinChunk - 1).utf8)
        let pipe = Pipe()
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            done.fulfill()
        }
        let start = Date()
        RemoteExec.writePaced(data, to: pipe.fileHandleForWriting)
        let elapsed = Date().timeIntervalSince(start)
        try? pipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 10)
        XCTAssertLessThan(elapsed, RemoteExec.stdinPause,
                          "a single-chunk script should not pause at all")
    }
}

/// The crash this pacing caused on launch: `ssh` fails fast (unreachable
/// host, refused auth, a paused host), the pipe's reader is gone, and the
/// next chunk we write kills the app. Instant, before any window appears.
final class RemoteExecPipeSafetyTests: XCTestCase {

    func testWritingToADeadReaderDoesNotCrash() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]          // gone immediately
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.1)

        // Several chunks' worth, so it can't slip through in one write.
        let data = Data(String(repeating: "x", count: RemoteExec.stdinChunk * 5).utf8)
        let written = RemoteExec.writePaced(data, to: inPipe.fileHandleForWriting)

        // Reaching this line at all is the assertion — before the fix the
        // process died here with SIGPIPE.
        XCTAssertLessThanOrEqual(written, data.count)
    }

    func testStopsWritingOnceTheChildIsGone() {
        let pipe = Pipe()
        let done = expectation(description: "drained")
        DispatchQueue.global().async {
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            done.fulfill()
        }
        var alive = true
        let data = Data(String(repeating: "z", count: RemoteExec.stdinChunk * 6).utf8)
        // Falls over after the first chunk, as a failing ssh would.
        let written = RemoteExec.writePaced(data, to: pipe.fileHandleForWriting,
                                            while: { defer { alive = false }; return alive })
        try? pipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(written, RemoteExec.stdinChunk,
                       "must stop at the first chunk rather than keep feeding a corpse")
    }
}
