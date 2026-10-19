import XCTest
import AppKit
@testable import OnyxLib

/// Shift-Return must reach the terminal as something a program can tell
/// from Return: ESC CR, the sequence Claude Code reads as "new line".
final class TerminalKeyTranslationTests: XCTestCase {

    func testShiftReturnIsEscCR() {
        XCTAssertEqual(TerminalKeyTranslation.bytes(keyCode: 36, modifiers: .shift), [0x1b, 0x0d])
        XCTAssertEqual(TerminalKeyTranslation.bytes(keyCode: 76, modifiers: .shift), [0x1b, 0x0d])
        // Caps lock and the like don't change it.
        XCTAssertEqual(TerminalKeyTranslation.bytes(keyCode: 36, modifiers: [.shift, .capsLock]),
                       [0x1b, 0x0d])
    }

    func testEverythingElseIsLeftToSwiftTerm() {
        XCTAssertNil(TerminalKeyTranslation.bytes(keyCode: 36, modifiers: []))
        XCTAssertNil(TerminalKeyTranslation.bytes(keyCode: 36, modifiers: [.shift, .command]))
        XCTAssertNil(TerminalKeyTranslation.bytes(keyCode: 36, modifiers: .option))
        XCTAssertNil(TerminalKeyTranslation.bytes(keyCode: 48, modifiers: .shift))  // Shift-Tab
    }
}
