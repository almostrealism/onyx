import XCTest
@testable import OnyxLib

// MARK: - SyntaxHighlighter Tests

final class SyntaxHighlighterTests: XCTestCase {

    func testHighlight_javaFile_hasNonPlainColors() {
        let javaCode = """
        public class Main {
            public static void main(String[] args) {
                int x = 42;
                System.out.println("Hello");
            }
        }
        """
        let result = SyntaxHighlighter.highlight(javaCode, fileName: "Main.java")
        // The result should be an AttributedString with colored runs,
        // not just a single plain-white run. Check that it differs from plain.
        var plain = AttributedString(javaCode)
        plain.foregroundColor = .white.opacity(0.85)
        XCTAssertNotEqual(result, plain, "Java code should have syntax-highlighted colors")
    }

    func testHighlight_pythonFile_hasNonPlainColors() {
        let pythonCode = """
        def hello():
            x = 42
            return "world"
        """
        let result = SyntaxHighlighter.highlight(pythonCode, fileName: "script.py")
        var plain = AttributedString(pythonCode)
        plain.foregroundColor = .white.opacity(0.85)
        XCTAssertNotEqual(result, plain, "Python code should have syntax-highlighted colors")
    }

    func testHighlight_jsonFile_hasNonPlainColors() {
        let jsonCode = """
        {"name": "test", "value": 42, "flag": true}
        """
        let result = SyntaxHighlighter.highlight(jsonCode, fileName: "data.json")
        var plain = AttributedString(jsonCode)
        plain.foregroundColor = .white.opacity(0.85)
        XCTAssertNotEqual(result, plain, "JSON code should have syntax-highlighted colors")
    }

    func testHighlight_unknownExtension_returnsPlain() {
        let content = "just some text"
        let result = SyntaxHighlighter.highlight(content, fileName: "readme.xyz")
        var plain = AttributedString(content)
        plain.foregroundColor = .white.opacity(0.85)
        XCTAssertEqual(result, plain, "Unknown extension should return plain white text")
    }
}

