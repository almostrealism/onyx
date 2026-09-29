import XCTest
import AppKit
import SwiftTerm
@testable import OnyxLib

/// Pasted text in zsh (`zle_highlight` paste=standout) and bash 5.1+ (active
/// region) is drawn in reverse video. On Onyx's transparent terminal
/// background that used to render as dark gray text on NOTHING: SwiftTerm
/// inverts the default background keeping its alpha of zero. These tests
/// render a real terminal view and look at the pixels.
final class ReverseVideoTests: XCTestCase {

    private func render(_ text: String, configure: (TerminalView) -> Void) -> NSBitmapImageRep {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        configure(tv)
        // Onyx hides the scroller (OnyxTerminalView.hideScroller); so do we.
        tv.subviews.filter { $0 is NSScroller }.forEach { $0.isHidden = true }
        // Hide the cursor: its block is light and opaque too.
        tv.feed(text: "\u{1b}[?25l" + text)
        let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
        tv.cacheDisplay(in: tv.bounds, to: rep)
        return rep
    }

    /// Pixels a reversed cell's background should produce: opaque and light.
    private func opaqueLightPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.alphaComponent > 0.9, c.redComponent > 0.8 { count += 1 }
            }
        }
        return count
    }

    private func visiblePixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0

        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 { count += 1 }
            }
        }
        return count
    }

    // Spaces, so every pixel measured is cell background, never a glyph.
    private let reversedSpaces = "\u{1b}[7m          \u{1b}[0m"

    func testReverseVideoGetsAnOpaqueLightBackground() {
        let rep = render(reversedSpaces) { OnyxTerminalView.applyColors(to: $0) }
        XCTAssertGreaterThan(opaqueLightPixels(rep), 100,
                             "reversed cells must be painted light and opaque, or pasted text is dark gray on nothing")
    }

    func testTheDefaultBackgroundStaysTransparent() {
        let rep = render("          ") { OnyxTerminalView.applyColors(to: $0) }
        XCTAssertEqual(visiblePixels(rep), 0,
                       "the window's vibrancy is the background; default cells must paint nothing")
    }

    /// The control: a plain alpha-zero background reproduces the bug, so the
    /// test above is measuring the thing that was broken.
    func testAPlainClearBackgroundLosesTheReversedBackground() {
        let rep = render(reversedSpaces) { tv in
            OnyxTerminalView.applyColors(to: tv)
            tv.nativeBackgroundColor = NSColor(white: 0.04, alpha: 0)
        }
        XCTAssertEqual(opaqueLightPixels(rep), 0)
    }
}
