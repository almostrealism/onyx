import XCTest
import AppKit
@testable import OnyxCore
@testable import OnyxLib

/// ⌘V in the file browser uploads files copied in Finder — and only files.
/// (The pasteboard itself isn't reachable from a headless test run, so
/// this checks what's kept from a read.)
final class FileBrowserPasteTests: XCTestCase {

    func testFileURLsAreKept() {
        let objects: [Any] = [NSURL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b")]
        XCTAssertEqual(FileBrowserManager.fileURLs(in: objects).map(\.path), ["/tmp/a.txt", "/tmp/b"])
    }

    func testWebLinksAndTextAreNot() {
        let objects: [Any] = [NSURL(string: "https://example.com")!, "/tmp/a.txt"]
        XCTAssertTrue(FileBrowserManager.fileURLs(in: objects).isEmpty)
        XCTAssertTrue(FileBrowserManager.fileURLs(in: nil).isEmpty)
    }
}
