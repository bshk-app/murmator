import AppKit
import SwiftUI
import XCTest
@testable import MurmurCaptions

/// Three lines of context per language without covering the presentation.
final class CaptionsLayoutTests: XCTestCase {
    func testA1080pScreenGetsSmallerTypeAndThreeLines() {
        let layout = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
        XCTAssertEqual(layout.fontSize, 25)
        XCTAssertEqual(layout.bandWidth, 1536)
        XCTAssertEqual(layout.transcriptLines, 3)
        XCTAssertEqual(layout.translationLines, 0)
        XCTAssertEqual(layout.bottomInset, 54)
    }

    func testTypeIsClampedOnTinyAndHugeScreens() {
        XCTAssertEqual(CaptionsLayout(screen: CGSize(width: 800, height: 400), translating: false).fontSize, 14)
        XCTAssertEqual(CaptionsLayout(screen: CGSize(width: 7680, height: 4320), translating: false).fontSize, 48)
    }

    func testTranslationHasThreeLinesWithoutTakingLinesFromTheSource() {
        let plain = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
        let translating = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: true)
        XCTAssertEqual(translating.transcriptLines, 3)
        XCTAssertEqual(translating.translationLines, 3)
        XCTAssertGreaterThan(translating.bandSize.height, plain.bandSize.height)
        XCTAssertLessThan(translating.bandSize.height, 1080 * 0.20, "the band must leave the slide visible")
    }

    func testTheTrackIsExactlyItsLines() {
        let one = CaptionsLayout.trackHeight(lines: 1, size: 60)
        let three = CaptionsLayout.trackHeight(lines: 3, size: 60)
        XCTAssertEqual(three, one * 3 + CaptionsLayout.lineSpacing(60) * 2)
    }

    /// A host that gives the band its own size (a strip under a slide) gets
    /// that size, and the extra height becomes lines, not empty space.
    func testAHostChosenSizeIsKeptAndFilledWithLines() {
        let screen = CGSize(width: 1920, height: 1080)
        let plain = CaptionsLayout(screen: screen, translating: true)
        let strip = CGSize(width: 1800, height: plain.bandSize.height * 1.8)
        let layout = CaptionsLayout(screen: screen, translating: true, size: strip)
        XCTAssertEqual(layout.bandSize, strip)
        XCTAssertGreaterThan(layout.transcriptLines, plain.transcriptLines)
        XCTAssertGreaterThan(layout.translationLines, plain.translationLines)
        let tiny = CaptionsLayout(screen: screen, translating: true, size: CGSize(width: 1800, height: 10))
        XCTAssertEqual(tiny.bandSize.height, tiny.minimumSize.height, "never smaller than three lines per language")
    }
}

@MainActor
final class CaptionsBandTests: XCTestCase {
    private func textViews(in view: NSView) -> [CaptionsTextView] {
        view.subviews.flatMap { ($0 as? CaptionsTextView).map { [$0] } ?? textViews(in: $0) }
    }

    private func host(translating: Bool) -> NSHostingView<CaptionsBand> {
        let layout = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: translating)
        let band = CaptionsBand(confirmed: "Привет", partial: "мир", translation: translating ? "Hello world" : "",
                                layout: layout, appearance: CaptionsAppearance())
        let view = NSHostingView(rootView: band)
        view.frame = NSRect(origin: .zero, size: layout.bandSize)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testTheBandHasTheLayoutSizeAndOneTrackPerLanguage() {
        let plain = host(translating: false)
        XCTAssertEqual(plain.fittingSize, CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false).bandSize)
        XCTAssertEqual(textViews(in: plain).map(\.textView.string), ["Привет мир"])
        let translating = host(translating: true)
        XCTAssertEqual(textViews(in: translating).map(\.textView.string), ["Привет мир", "Hello world"])
    }
}
