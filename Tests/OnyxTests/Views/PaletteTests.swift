import XCTest
import SwiftUI
import AppKit
@testable import OnyxLib

final class PaletteTests: XCTestCase {

    private func rgb(_ color: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    // MARK: - NSColor(hex:)

    func test_nscolorHex_parsesComponents() {
        let c = rgb(NSColor(hex: "FF6B6B"))
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.r, 1.0, accuracy: 0.01)
        XCTAssertEqual(c!.g, CGFloat(0x6B) / 255, accuracy: 0.01)
        XCTAssertEqual(c!.b, CGFloat(0x6B) / 255, accuracy: 0.01)
    }

    func test_nscolorHex_stripsNonHexLikeAHashPrefix() {
        XCTAssertNotNil(NSColor(hex: "#66CCFF"))
    }

    func test_nscolorHex_rejectsMalformed() {
        XCTAssertNil(NSColor(hex: "xyz"))
        XCTAssertNil(NSColor(hex: "FFF"))     // 3-digit shorthand unsupported
        XCTAssertNil(NSColor(hex: ""))
    }

    // MARK: - Named palette resolves to its hex

    func test_palette_resolvesExpectedColors() {
        let cases: [(Color, String)] = [
            (.onyxBlue,   "66CCFF"),
            (.onyxGreen,  "6BFF8E"),
            (.onyxAmber,  "FFD06B"),
            (.onyxRed,    "FF6B6B"),
            (.onyxPurple, "C06BFF"),
        ]
        for (color, hex) in cases {
            guard let named = rgb(NSColor(color)),
                  let expected = rgb(NSColor(hex: hex)) else {
                XCTFail("could not resolve \(hex)"); continue
            }
            XCTAssertEqual(named.r, expected.r, accuracy: 0.02, "\(hex) red")
            XCTAssertEqual(named.g, expected.g, accuracy: 0.02, "\(hex) green")
            XCTAssertEqual(named.b, expected.b, accuracy: 0.02, "\(hex) blue")
        }
    }
}
