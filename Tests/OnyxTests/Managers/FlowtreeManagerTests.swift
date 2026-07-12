import XCTest
@testable import OnyxLib

final class FlowtreeManagerTests: XCTestCase {

    func test_composePrompt_includesTitleNotesAndURL() {
        let prompt = FlowtreeManager.composePrompt(
            title: "Fix the login bug",
            notes: "Users can't sign in with SSO.",
            url: "https://tracker/issue/42")
        XCTAssertTrue(prompt.contains("Fix the login bug"))
        XCTAssertTrue(prompt.contains("Users can't sign in with SSO."))
        XCTAssertTrue(prompt.contains("Reminder link: https://tracker/issue/42"))
        // Sections separated by blank lines.
        XCTAssertTrue(prompt.contains("\n\n"))
    }

    func test_composePrompt_omitsMissingParts() {
        let prompt = FlowtreeManager.composePrompt(title: "Just a title", notes: nil, url: nil)
        XCTAssertEqual(prompt, "Just a title")
    }

    func test_composePrompt_skipsBlankNotes() {
        let prompt = FlowtreeManager.composePrompt(title: "T", notes: "   ", url: "https://x")
        XCTAssertEqual(prompt, "T\n\nReminder link: https://x")
    }

    func test_composePrompt_allEmpty_isEmpty() {
        XCTAssertEqual(FlowtreeManager.composePrompt(title: nil, notes: nil, url: nil), "")
    }
}
