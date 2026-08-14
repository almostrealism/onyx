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
