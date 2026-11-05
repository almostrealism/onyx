import XCTest
@testable import OnyxCore

/// A click on terminal output opens web and mail links, nothing else.
final class TerminalLinksTests: XCTestCase {

    func testWebAndMailLinksOpen() {
        XCTAssertEqual(TerminalLinks.openable("https://github.com/a/b/pull/7")?.absoluteString,
                       "https://github.com/a/b/pull/7")
        XCTAssertNotNil(TerminalLinks.openable("http://localhost:8080/x"))
        XCTAssertNotNil(TerminalLinks.openable("mailto:me@example.com"))
    }

    /// Output can be anyone's: a click must never run something here.
    func testOtherSchemesDoNot() {
        for text in ["file:///etc/passwd", "ssh://host", "x-onyx://do", "tel:123",
                     "javascript:alert(1)", "https://", "not a url"] {
            XCTAssertNil(TerminalLinks.openable(text), text)
        }
    }

    func testSentencePunctuationIsNotPartOfTheLink() {
        XCTAssertEqual(TerminalLinks.openable("https://example.com/x.")?.absoluteString,
                       "https://example.com/x")
        XCTAssertEqual(TerminalLinks.openable("https://example.com/a?b=1,")?.absoluteString,
                       "https://example.com/a?b=1")
    }
}
