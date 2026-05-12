import XCTest
@testable import OnyxLib

// Settings staged-text behavior for numeric font-size fields.
//
// Regression: the previous implementation clamped the value on every
// keystroke via a Binding<String>.set, so deleting a digit en route to a
// new value (e.g. editing 14 → 1 → 18) would snap to the minimum mid-edit
// and the user could never reach the target. The fix stages the typed
// text in @State and only parses/clamps on Save. These tests pin the
// parse-and-clamp behavior at the boundary, plus document the "don't
// fight the user mid-edit" contract via the partial-input case.

final class SettingsFontSizeTests: XCTestCase {

    func testParsedFontSize_acceptsValuesInRange() {
        XCTAssertEqual(SettingsView.parsedFontSize("8"), 8)
        XCTAssertEqual(SettingsView.parsedFontSize("13"), 13)
        XCTAssertEqual(SettingsView.parsedFontSize("14"), 14)
        XCTAssertEqual(SettingsView.parsedFontSize("48"), 48)
        XCTAssertEqual(SettingsView.parsedFontSize("64"), 64)
    }

    func testParsedFontSize_clampsBelowMinimum() {
        // On Save (not while typing), too-small values clamp up.
        XCTAssertEqual(SettingsView.parsedFontSize("1"), 8)
        XCTAssertEqual(SettingsView.parsedFontSize("0"), 8)
    }

    func testParsedFontSize_clampsAboveMaximum() {
        // A fat-finger on 144 doesn't blow up the UI.
        XCTAssertEqual(SettingsView.parsedFontSize("144"), 64)
        XCTAssertEqual(SettingsView.parsedFontSize("1000"), 64)
    }

    func testParsedFontSize_returnsNilForUnparseable() {
        // Empty or garbage text returns nil — caller keeps the current
        // value rather than commit a default. This is what protects
        // accidental clears from wiping the user's preference.
        XCTAssertNil(SettingsView.parsedFontSize(""))
        XCTAssertNil(SettingsView.parsedFontSize("   "))
        XCTAssertNil(SettingsView.parsedFontSize("abc"))
        XCTAssertNil(SettingsView.parsedFontSize("12.5"))  // strict Int — fractional rejected, caller keeps current
    }

    func testParsedFontSize_trimsWhitespace() {
        XCTAssertEqual(SettingsView.parsedFontSize("  14  "), 14)
        XCTAssertEqual(SettingsView.parsedFontSize("\t16\n"), 16)
    }

    func testStagedTextContract_isLooserThanModel() {
        // The whole point of staging text in @State: the in-flight string
        // is allowed to be ANY string, including ones outside the valid
        // range, partial entries, or unparseable garbage. Only on Save
        // does the parser run. This test documents what *should* happen
        // when a user types "14" by going 1 → 14: each intermediate value
        // must be representable as staged text without being silently
        // rewritten. We don't test SwiftUI bindings here — just verify
        // the parser ignores intermediate states (returns nil for "" or
        // leaves valid values alone) so the staging layer doesn't have
        // to fight.
        let inflight = ["", "1", "14"]  // a user's keystroke trajectory
        let committedFromIntermediate = inflight.compactMap(SettingsView.parsedFontSize)
        // Only the final value (after parsing) commits, with clamping.
        // Empty stays nil; "1" clamps to 8; "14" is in range.
        XCTAssertEqual(committedFromIntermediate, [8, 14])
        // The important point: during typing none of this runs. The user
        // gets a clean keystroke trajectory in the text field, and only
        // the FINAL value (whatever's in the field at Save time) is parsed.
    }
}
