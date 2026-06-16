import XCTest
@testable import OnyxLib

final class TextSanitizerTests: XCTestCase {

    func test_curlyDoubleQuotes_becomeStraight() {
        XCTAssertEqual(TextSanitizer.sanitize("\u{201C}hello\u{201D}"), "\"hello\"")
    }

    func test_curlySingleQuotes_becomeStraight() {
        XCTAssertEqual(TextSanitizer.sanitize("\u{2018}hi\u{2019}"), "'hi'")
    }

    func test_apostrophe_curlyToStraight() {
        // The most common real case: "it's" auto-curled to it\u{2019}s.
        XCTAssertEqual(TextSanitizer.sanitize("it\u{2019}s"), "it's")
    }

    func test_primes_becomeStraightQuotes() {
        XCTAssertEqual(TextSanitizer.sanitize("5\u{2032}6\u{2033}"), "5'6\"")
    }

    func test_lowAndReversedQuotes() {
        XCTAssertEqual(TextSanitizer.sanitize("\u{201E}x\u{201F} \u{201A}y\u{201B}"),
                       "\"x\" 'y'")
    }

    func test_enDash_becomesHyphen() {
        XCTAssertEqual(TextSanitizer.sanitize("a\u{2013}b"), "a-b")
    }

    func test_emDash_becomesDoubleHyphen() {
        XCTAssertEqual(TextSanitizer.sanitize("a\u{2014}b"), "a--b")
    }

    func test_ellipsis_becomesThreeDots() {
        XCTAssertEqual(TextSanitizer.sanitize("wait\u{2026}"), "wait...")
    }

    func test_mixed_allStylizedRemoved() {
        let input = "\u{201C}It\u{2019}s\u{2026} a \u{2013} test\u{201D}"
        let out = TextSanitizer.sanitize(input)
        XCTAssertEqual(out, "\"It's... a - test\"")
        XCTAssertFalse(TextSanitizer.containsStylized(out),
                       "result must contain no stylized characters at all")
    }

    func test_plainTextUnchanged() {
        let s = "plain \"straight\" 'quotes' - and -- dashes ... fine"
        XCTAssertEqual(TextSanitizer.sanitize(s), s)
    }

    func test_emptyString() {
        XCTAssertEqual(TextSanitizer.sanitize(""), "")
    }

    func test_containsStylized_detection() {
        XCTAssertTrue(TextSanitizer.containsStylized("a\u{201C}b"))
        XCTAssertFalse(TextSanitizer.containsStylized("a\"b"))
    }

    func test_sanitizeIsIdempotent() {
        let once = TextSanitizer.sanitize("\u{201C}x\u{201D}\u{2014}\u{2026}")
        XCTAssertEqual(TextSanitizer.sanitize(once), once)
    }
}
