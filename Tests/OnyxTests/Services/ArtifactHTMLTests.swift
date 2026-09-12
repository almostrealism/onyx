import XCTest
@testable import OnyxLib

/// Agent-authored HTML. The use case is a status page an agent builds
/// and then tells the user to go and read, so the two things that matter
/// are that a page the agent styled arrives intact, and that its links
/// go somewhere rather than replacing the page in place.
final class ArtifactHTMLTests: XCTestCase {

    // MARK: - Whole documents pass through

    /// An agent that wrote a styled page has already decided how it looks
    /// and tested it that way. Wrapping it would break that.
    func testAFullDocumentIsUntouched() {
        let page = "<!DOCTYPE html><html><head><style>body{background:#fff}</style></head>"
                 + "<body><h1>Report</h1></body></html>"
        XCTAssertTrue(ArtifactHTML.isFullDocument(page))
        XCTAssertEqual(ArtifactHTML.prepared(page), page)
    }

    func testDoctypeDetectionIgnoresCaseAndLeadingSpace() {
        XCTAssertTrue(ArtifactHTML.isFullDocument("\n  <!doctype HTML><html></html>"))
        XCTAssertTrue(ArtifactHTML.isFullDocument("<HTML><body>x</body></HTML>"))
    }

    // MARK: - Fragments get somewhere readable

    /// The panel is black. An unstyled fragment would be black text on
    /// it — published, and invisible.
    func testAFragmentIsWrappedWithReadableStyling() {
        let out = ArtifactHTML.prepared("<h1>Status</h1><p>All green</p>")
        XCTAssertTrue(out.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(out.contains("<h1>Status</h1>"), "the content must survive verbatim")
        XCTAssertTrue(out.contains("color-scheme: dark"))
        XCTAssertTrue(out.contains("table"), "a status page is mostly a table")
    }

    /// A page ABOUT html is still a fragment — the marker has to be
    /// structural, not a mention.
    func testAFragmentDiscussingHTMLIsStillAFragment() {
        let talking = "<p>Wrap it in <code>&lt;html&gt;</code> like this</p>"
        XCTAssertFalse(ArtifactHTML.isFullDocument(talking))
        XCTAssertTrue(ArtifactHTML.prepared(talking).contains("color-scheme: dark"))
    }

    func testEmptyContentIsStillARenderablePage() {
        XCTAssertTrue(ArtifactHTML.prepared("").hasPrefix("<!DOCTYPE html>"))
    }

    // MARK: - Links leave the panel

    /// Following a link inside the panel would replace the status page
    /// the agent just published, with no way back to it.
    func testRealLinksOpenOutside() {
        XCTAssertTrue(ArtifactHTML.shouldOpenExternally(URL(string: "https://gitlab.com/x/y/-/merge_requests/3")))
        XCTAssertTrue(ArtifactHTML.shouldOpenExternally(URL(string: "http://localhost:8080/report")))
        XCTAssertTrue(ArtifactHTML.shouldOpenExternally(URL(string: "mailto:someone@example.com")))
    }

    /// The initial loadHTMLString is a navigation too. Cancelling it
    /// would show an empty panel.
    func testTheInitialLoadIsNotTreatedAsALink() {
        XCTAssertFalse(ArtifactHTML.shouldOpenExternally(URL(string: "about:blank")))
        XCTAssertFalse(ArtifactHTML.shouldOpenExternally(nil))
    }

    /// Jumping to a heading in the page you're reading is movement
    /// within it, not a link out of it.
    func testInPageAnchorsStayPut() {
        XCTAssertFalse(ArtifactHTML.shouldOpenExternally(URL(string: "#section-2")))
    }
}
