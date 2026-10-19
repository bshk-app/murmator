import AppKit
import XCTest
import MurmurKit
@testable import Murmur

/// The draft is drawn on top of what you are writing, so it must be where
/// the text will land, never block a click there, and get out of the way -
/// to the bottom of the screen - when there is something to read.
@MainActor
final class HUDCaretIndicatorTests: XCTestCase {
    private var visible: CGRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }
    private var caret: CGRect { CGRect(x: visible.midX, y: visible.midY, width: 0, height: 18) }

    private func hud(_ lookup: CaretLocator.Lookup) -> (HUDController, () -> Int) {
        let hud = HUDController()
        var asked = 0
        hud.locateCaret = { _ in asked += 1; return lookup }
        return (hud, { asked })
    }

    func testFoundCaretGetsTheDraftDrawnThere() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        XCTAssertTrue(hud.model.showsCaretIndicator)
        XCTAssertFalse(hud.model.showsCompactPill)
        let ghost = try XCTUnwrap(hud.model.ghost)
        let first = try XCTUnwrap(ghost.lines.first)
        XCTAssertEqual(first.origin.x, caret.minX)
        XCTAssertEqual(first.origin.y + ghost.lineHeight / 2, caret.midY, accuracy: 1)
        XCTAssertEqual(hud.panelFrame, ghost.canvas)
        XCTAssertTrue(ghost.canvas.contains(CGPoint(x: caret.minX, y: caret.midY)))
    }

    /// What is heard shows up at the caret as it is heard, settled and
    /// pending words apart.
    func testTheDraftShowsWhatIsHeard() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        XCTAssertEqual(try XCTUnwrap(hud.model.ghost).lines.flatMap(\.words), [])
        hud.update(confirmed: "hello", partial: "world")
        XCTAssertEqual(try XCTUnwrap(hud.model.ghost).lines.flatMap(\.words),
                       [GhostWord(text: "hello", confirmed: true), GhostWord(text: "world", confirmed: false)])
    }

    func testTheOriginalCaretIndicatorReturnsAfterATransientMissingAnswer() async throws {
        let hud = HUDController()
        var lookup = CaretLocator.Lookup.notFound
        hud.locateCaret = { _ in lookup }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .caret)
        XCTAssertTrue(hud.model.showsCompactPill)
        lookup = .found(CaretSpot(caret, font: FieldFont(name: "Helvetica", size: 13)))
        try await waitUntil { hud.model.showsCaretIndicator }
        hud.update(confirmed: "", partial: "слова у каретки")
        let ghost = try XCTUnwrap(hud.model.ghost)
        XCTAssertEqual(ghost.lines.flatMap(\.words).map(\.text), ["слова", "у", "каретки"])
        XCTAssertEqual(ghost.markerWidth, HUDController.markerWidth(returnGlyph: true))
        XCTAssertEqual(ghost.font.fontName, "Helvetica")
        XCTAssertFalse(hud.model.showStop)
        XCTAssertFalse(hud.panelTakesClicks)
        XCTAssertFalse(hud.previewPanelIsVisible)
        hud.dismiss()
    }

    func testTheCaretSavedBeforeModelLoadingIsUsedWithoutAnotherInitialLookup() throws {
        let (hud, asked) = hud(.notFound)
        let saved = CaretSpot(caret, font: FieldFont(name: "Helvetica", size: 13))
        hud.begin(lang: "RU", confirmsWithReturn: true, style: .caret, initialCaret: .found(saved))
        XCTAssertEqual(asked(), 0)
        XCTAssertTrue(hud.model.showsCaretIndicator)
        let line = try XCTUnwrap(hud.model.ghost?.lines.first)
        XCTAssertEqual(line.origin.x, caret.minX)
        XCTAssertTrue(line.hasMarker)
        hud.dismiss()
    }

    func testAStalledInitialCaretLookupIsNotPolled() async throws {
        let (hud, asked) = hud(.stalled)
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(asked(), 1)
        hud.dismiss()
    }

    /// The field's type is asked for once, when the take starts.
    func testTheFieldsTypeIsReadOnceAndUsed() async throws {
        let hud = HUDController()
        var asks: [Bool] = []
        let spot = CaretSpot(CGRect(x: caret.minX, y: caret.minY, width: 0, height: 16),
                             font: FieldFont(name: "Helvetica", size: 13))
        hud.locateCaret = { asks.append($0); return .found(spot) }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        XCTAssertEqual(try XCTUnwrap(hud.model.ghost).font.fontName, "Helvetica")
        XCTAssertEqual(try XCTUnwrap(hud.model.ghost).font.pointSize, 13)
        try await waitUntil { asks.count > 2 }
        XCTAssertEqual(asks.first, true)
        XCTAssertEqual(Set(asks.dropFirst()), [false])
    }

    /// It sits on the text you are writing: clicks there must reach the text,
    /// even in tap-on mode, where the other pills offer a Stop button.
    func testTheDraftTakesNoClicksEvenInTapMode() {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .caret)
        XCTAssertFalse(hud.model.showStop)
        XCTAssertFalse(hud.panelTakesClicks)
    }

    func testNoCaretFallsBackToTheCompactCapsule() {
        for lookup in [CaretLocator.Lookup.notFound, .stalled] {
            let (hud, _) = hud(lookup)
            hud.begin(lang: "RU", interactive: true, style: .caret)
            XCTAssertFalse(hud.model.showsCaretIndicator)
            XCTAssertTrue(hud.model.showsCompactPill)
            XCTAssertTrue(hud.model.showStop, "the capsule keeps its Stop button")
            XCTAssertTrue(hud.panelTakesClicks)
        }
    }

    func testAnUnavailableCaretStillShowsTheLiveDraftBesideTheCapsule() throws {
        for lookup in [CaretLocator.Lookup.notFound, .stalled] {
            let (hud, _) = hud(lookup)
            hud.begin(lang: "RU", interactive: true, style: .caret)
            let capsule = try XCTUnwrap(hud.panelFrame)
            hud.update(confirmed: "точные слова", partial: "быстрый черновик")
            let draft = try XCTUnwrap(hud.model.ghost, "A missing AX caret must not hide the realtime text")
            XCTAssertEqual(draft.lines.flatMap(\.words).map(\.text),
                           ["точные", "слова", "быстрый", "черновик"])
            XCTAssertEqual(hud.panelFrame, capsule, "The compact controls must keep their size and position")
            XCTAssertTrue(hud.previewPanelIsVisible)
            XCTAssertFalse(hud.previewPanelTakesClicks)
            let preview = try XCTUnwrap(hud.previewPanelFrame)
            hud.finalizing()
            hud.update(confirmed: "готовый точный результат", partial: "")
            XCTAssertEqual(hud.model.ghost?.lines.flatMap(\.words).map(\.text), ["готовый", "точный", "результат"])
            XCTAssertEqual(hud.previewPanelFrame, preview)
            XCTAssertEqual(hud.panelFrame, capsule)
            hud.dismiss()
            XCTAssertFalse(hud.previewPanelIsVisible)
        }
    }

    func testExplicitCompactStyleKeepsItsStatusOnlyPresentation() {
        let (hud, _) = hud(.notFound)
        hud.begin(lang: "RU", style: .compact)
        hud.update(confirmed: "", partial: "быстрый черновик")
        XCTAssertTrue(hud.model.showsCompactPill)
        XCTAssertNil(hud.model.ghost)
        XCTAssertFalse(hud.previewPanelIsVisible)
        hud.dismiss()
    }

    func testFallbackDraftDisappearsBeforeTheNextUtteranceAndAfterDelivery() {
        let (hud, _) = hud(.notFound)
        hud.begin(lang: "RU", style: .caret)
        hud.update(confirmed: "", partial: "первая запись")
        XCTAssertTrue(hud.previewPanelIsVisible)
        hud.begin(lang: "RU", style: .caret)
        XCTAssertNil(hud.model.ghost)
        XCTAssertFalse(hud.previewPanelIsVisible)
        hud.update(confirmed: "", partial: "вторая запись")
        hud.finish("точный результат", delivery: .typed)
        XCTAssertFalse(hud.previewPanelIsVisible)
    }

    func testOtherStylesDoNotAskForTheCaret() {
        for style in [HUDStyle.compact, .full] {
            let (hud, asked) = hud(.found(CaretSpot(caret)))
            hud.begin(lang: "RU", style: style)
            XCTAssertEqual(asked(), 0)
            XCTAssertFalse(hud.model.showsCaretIndicator)
        }
    }

    /// The window is the area the lines can cover: words arriving, or a
    /// badge, change what is drawn in it, not the window.
    func testTheWindowKeepsItsSizeAndPlaceWhileYouSpeak() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", confirmsWithReturn: true, style: .caret)
        let atStart = try XCTUnwrap(hud.panelFrame)
        hud.update(confirmed: "words", partial: "more words")
        hud.update(confirmed: String(repeating: "many words ", count: 12), partial: "")
        hud.finalizing()
        hud.willSubmit()
        hud.translating()
        XCTAssertTrue(hud.model.showsCaretIndicator)
        XCTAssertEqual(hud.panelFrame, atStart)
    }

    /// A tap-on take keeps room for its ⏎ from the start, so the line does
    /// not reflow when it shows.
    func testTheMarkerIsAsWideAsWhatThisUtteranceCanShow() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        let hold = try XCTUnwrap(hud.model.ghost).markerWidth
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .caret)
        XCTAssertLessThan(hold, try XCTUnwrap(hud.model.ghost).markerWidth)
    }

    /// Text that could not be typed, or an error, must be read - in the full
    /// pill at the bottom of the screen, not over the text.
    func testUndeliveredTextMovesToTheFullPillAtTheBottom() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        let atCaret = try XCTUnwrap(hud.panelFrame)
        hud.finish("the words", delivery: .failed("Field is protected — press ⌘V"))
        XCTAssertFalse(hud.model.showsCaretIndicator)
        XCTAssertNil(hud.model.ghost)
        let after = try XCTUnwrap(hud.panelFrame)
        XCTAssertGreaterThan(after.height, atCaret.height)
        XCTAssertLessThan(after.minY, atCaret.minY)
    }

    func testAnErrorMovesToTheFullPillAtTheBottom() throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        let atCaret = try XCTUnwrap(hud.panelFrame)
        hud.error("No microphone")
        XCTAssertFalse(hud.model.showsCaretIndicator)
        XCTAssertLessThan(try XCTUnwrap(hud.panelFrame).minY, atCaret.minY)
    }

    func testTheDraftFollowsTheCaretWhenItMoves() async throws {
        let hud = HUDController()
        var current = caret
        hud.locateCaret = { _ in .found(CaretSpot(current)) }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        hud.update(confirmed: "words", partial: "")
        let before = try XCTUnwrap(hud.panelFrame)
        current = current.offsetBy(dx: 0, dy: -60)        // the window scrolled
        try await waitUntil { hud.panelFrame != before }
        XCTAssertEqual(try XCTUnwrap(hud.panelFrame).minY, before.minY - 60, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(hud.model.ghost).lines.flatMap(\.words).map(\.text), ["words"])
    }

    /// A field losing focus for a moment must not send the draft flying to
    /// the bottom of the screen mid-sentence.
    func testALostCaretLeavesTheDraftWhereItWas() async throws {
        let hud = HUDController()
        var lookup = CaretLocator.Lookup.found(CaretSpot(caret))
        hud.locateCaret = { _ in lookup }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        let before = try XCTUnwrap(hud.panelFrame)
        lookup = .notFound
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(hud.model.showsCaretIndicator)
        XCTAssertEqual(hud.panelFrame, before)
    }

    /// An app that stopped answering costs one timeout, not one every tick.
    func testAStalledAppIsNotAskedAgain() async throws {
        let hud = HUDController()
        var asked = 0
        hud.locateCaret = { _ in asked += 1; return asked == 1 ? .found(CaretSpot(self.caret)) : .stalled }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked, 2)
    }

    func testTrackingStopsWhenTheTakeEnds() async throws {
        let hud = HUDController()
        var asked = 0
        hud.locateCaret = { _ in asked += 1; return .found(CaretSpot(self.caret)) }
        hud.caretTrackingInterval = .milliseconds(10)
        hud.begin(lang: "RU", style: .caret)
        hud.finish("the words", delivery: .typed)
        let after = asked
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(asked, after)
    }

    /// Return, then right ⌘ again straight away: the first take's fade must
    /// not hide the second one when it ends.
    func testANewTakeOutlivesTheLastOnesFade() async throws {
        let (hud, _) = hud(.found(CaretSpot(caret)))
        hud.begin(lang: "RU", style: .caret)
        hud.finish("the words", delivery: .typed)
        hud.begin(lang: "RU", style: .caret)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(hud.panelIsVisible)
        XCTAssertTrue(hud.model.showsCaretIndicator)
        hud.dismiss()
        try await waitUntil { !hud.panelIsVisible }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}

/// Which display a caret is on.
final class CaretScreenTests: XCTestCase {
    /// Two displays side by side: a caret on the seam, or just past it, is
    /// on the second one - not the first, which a 1pt slack would also touch.
    func testTheCaretsDisplayIsTheOneHoldingIt() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        func display(_ x: CGFloat) -> Int? {
            HUDController.screenIndex(containing: CGRect(x: x, y: 400, width: 0, height: 18), in: frames)
        }
        XCTAssertEqual(display(1440), 1)
        XCTAssertEqual(display(1440.5), 1)
        XCTAssertEqual(display(1439), 0)
        XCTAssertEqual(display(-0.5), 0, "off every display by a hair: the nearest")
    }
}

/// Turning what apps answer into a caret, from answers the probe saw.
final class CaretResolverTests: XCTestCase {
    private struct Source: CaretTextSource {
        var selectedRange: CFRange?
        var rects: [Int: CGRect] = [:]          // keyed by location * 10 + length
        var strings: [Int: String] = [:]
        var markerSelection: MarkerSelection?

        func bounds(of range: CFRange) -> CGRect? { rects[range.location * 10 + range.length] }
        func string(in range: CFRange) -> String? { strings[range.location * 10 + range.length] }
    }

    private func caret(_ source: Source) -> CGRect? {
        // Like the live check: a rect with no height is an app with no idea.
        CaretResolver.caret(in: source, isPlausible: { $0.height > 1 })
    }

    /// Raycast, native fields: the empty range is the caret.
    func testTheEmptyRangeIsTheCaret() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [50: CGRect(x: 120, y: 40, width: 0, height: 18)])
        XCTAssertEqual(caret(source), CGRect(x: 120, y: 40, width: 0, height: 18))
    }

    /// Terminal: no answer for the empty range, so the character before it.
    func testOtherwiseTheRightEdgeOfThePreviousCharacter() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [50: .zero, 41: CGRect(x: 100, y: 40, width: 8, height: 14)],
                            strings: [41: "a"])
        XCTAssertEqual(caret(source), CGRect(x: 108, y: 40, width: 0, height: 14))
    }

    /// After Return the character before the caret is the line break, on the
    /// line above. The caret starts the next one.
    func testNotTheLineBreakBeforeIt() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [41: CGRect(x: 300, y: 40, width: 8, height: 14),
                                    51: CGRect(x: 10, y: 60, width: 8, height: 14)],
                            strings: [41: "\n"])
        XCTAssertEqual(caret(source), CGRect(x: 10, y: 60, width: 0, height: 14))
    }

    // TextEdit on macOS 27, the demo page: a 60pt heading with 50pt of space
    // after it, then an empty 40pt paragraph. The empty range comes back one
    // line (48pt) too high wherever the caret is; character boxes are right.

    /// The caret on the empty paragraph: its line break's box is the line.
    func testTextEditsEmptyLineIsWhereItsLineBreakIs() {
        let source = Source(selectedRange: CFRange(location: 8, length: 0),
                            rects: [80: CGRect(x: 300, y: 255.7, width: 0, height: 48),
                                    81: CGRect(x: 295, y: 303.7, width: 1325, height: 96),
                                    71: CGRect(x: 552.5, y: 180, width: 1067.5, height: 73.7)],
                            strings: [81: "\n", 71: "\n"])
        XCTAssertEqual(caret(source), CGRect(x: 300, y: 303.7, width: 0, height: 48))
    }

    /// Mid-line, after "Однако test": TextEdit's x is right, its line is the one above.
    func testTextEditsCaretAfterAWordIsOnThatWordsLine() {
        let source = Source(selectedRange: CFRange(location: 19, length: 0),
                            rects: [190: CGRect(x: 519.6, y: 255.6, width: 0, height: 48.1),
                                    191: CGRect(x: 295, y: 303.7, width: 1325, height: 96.1),
                                    181: CGRect(x: 507, y: 303.7, width: 12.6, height: 48.1)],
                            strings: [191: "\n", 181: "t"])
        XCTAssertEqual(caret(source), CGRect(x: 519.6, y: 303.7, width: 0, height: 48.1))
    }

    /// After the last line break nothing is measured: the answer on the
    /// break's own line goes one line down.
    func testTextEditsCaretAfterTheLastLineBreakStartsTheNextLine() {
        let source = Source(selectedRange: CFRange(location: 20, length: 0),
                            rects: [200: CGRect(x: 300, y: 303.75, width: 0, height: 48),
                                    191: CGRect(x: 295, y: 303.5, width: 1325, height: 96)],
                            strings: [191: "\n"])
        XCTAssertEqual(caret(source), CGRect(x: 300, y: 351.75, width: 0, height: 48))
    }

    /// At the end of the text, after a character: that character's line.
    func testTheCaretAtTheEndIsOnTheLastCharactersLine() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [50: CGRect(x: 350, y: 255.6, width: 0, height: 48),
                                    41: CGRect(x: 338, y: 303.7, width: 12, height: 48)],
                            strings: [41: "o"])
        XCTAssertEqual(caret(source), CGRect(x: 350, y: 303.7, width: 0, height: 48))
    }

    /// An answer already on the line is kept as it is - beside a character,
    /// on the line after a break - whatever the characters' own boxes.
    func testAnAnswerOnItsLineIsKept() {
        let midLine = Source(selectedRange: CFRange(location: 5, length: 0),
                             rects: [50: CGRect(x: 120, y: 40, width: 0, height: 18),
                                     51: CGRect(x: 120, y: 42, width: 8, height: 14)],
                             strings: [51: "a"])
        XCTAssertEqual(caret(midLine), CGRect(x: 120, y: 40, width: 0, height: 18))
        let afterBreak = Source(selectedRange: CFRange(location: 5, length: 0),
                                rects: [50: CGRect(x: 10, y: 60, width: 0, height: 18),
                                        41: CGRect(x: 300, y: 40, width: 8, height: 18)],
                                strings: [41: "\n"])
        XCTAssertEqual(caret(afterBreak), CGRect(x: 10, y: 60, width: 0, height: 18))
    }

    /// At a wrap the caret can end the upper line while the next character
    /// starts the lower one; at the end of the character before it, on that
    /// one's line, it is right. TextEdit's answer at the start of the lower
    /// line has its x but the upper line's y, and goes down.
    func testAWrappedLineKeepsACaretAtItsEnd() {
        let rects: [Int: CGRect] = [51: CGRect(x: 10, y: 60, width: 8, height: 18),
                                    41: CGRect(x: 492, y: 40, width: 8, height: 18)]
        var atEnd = Source(selectedRange: CFRange(location: 5, length: 0), rects: rects,
                           strings: [51: "w", 41: " "])
        atEnd.rects[50] = CGRect(x: 500, y: 40, width: 0, height: 18)
        XCTAssertEqual(caret(atEnd), CGRect(x: 500, y: 40, width: 0, height: 18))
        var lineAbove = atEnd
        lineAbove.rects[50] = CGRect(x: 10, y: 40, width: 0, height: 18)
        XCTAssertEqual(caret(lineAbove), CGRect(x: 10, y: 60, width: 0, height: 18))
    }

    /// Some apps measure a character by its glyph, shorter than the caret.
    func testAGlyphTightBoxIsStillTheCaretsLine() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [50: CGRect(x: 120, y: 40, width: 0, height: 40),
                                    51: CGRect(x: 120, y: 45, width: 8, height: 8)],
                            strings: [51: "a"])
        XCTAssertEqual(caret(source), CGRect(x: 120, y: 40, width: 0, height: 40))
    }

    /// Only the line moves: right-to-left, the caret is on the right of the
    /// character after it.
    func testMovingToTheLineKeepsTheCaretsX() {
        let source = Source(selectedRange: CFRange(location: 5, length: 0),
                            rects: [50: CGRect(x: 500, y: 40, width: 0, height: 18),
                                    51: CGRect(x: 480, y: 60, width: 20, height: 18)],
                            strings: [51: "א"])
        XCTAssertEqual(caret(source), CGRect(x: 500, y: 60, width: 0, height: 18))
    }

    /// The end of a selection, where typing would replace it.
    func testASelectionEndsWhereItEnds() {
        let source = Source(selectedRange: CFRange(location: 2, length: 3),
                            rects: [50: CGRect(x: 140, y: 40, width: 0, height: 18)])
        XCTAssertEqual(caret(source)?.minX, 140)
    }

    /// bb, ChatGPT with text: a zero-width marker at the caret.
    func testANarrowMarkerIsTheCaret() {
        let source = Source(markerSelection: MarkerSelection(
            bounds: CGRect(x: 814, y: 1144, width: 0, height: 16), isCollapsed: true))
        XCTAssertEqual(caret(source), CGRect(x: 814, y: 1144, width: 0, height: 16))
    }

    /// bb's empty field: the whole line's box, 654pt wide. The caret starts
    /// it - the right edge is what sent the indicator off to the right.
    func testAnEmptyLineIsMeasuredWhole() {
        let source = Source(markerSelection: MarkerSelection(
            bounds: CGRect(x: 803, y: 1141, width: 654, height: 23), isCollapsed: true))
        XCTAssertEqual(caret(source), CGRect(x: 803, y: 1141, width: 0, height: 23))
    }

    func testASelectedMarkerRangeEndsOnTheRight() {
        let source = Source(markerSelection: MarkerSelection(
            bounds: CGRect(x: 100, y: 40, width: 80, height: 16), isCollapsed: false))
        XCTAssertEqual(caret(source)?.minX, 180)
    }

    /// Chromium answers the plain range with a zero rect at the screen
    /// corner; that is no answer, and the marker gets asked.
    func testAZeroRectIsNoAnswer() {
        let source = Source(selectedRange: CFRange(location: 0, length: 0),
                            rects: [0: .zero, 1: .zero],
                            markerSelection: MarkerSelection(
                                bounds: CGRect(x: 814, y: 1144, width: 0, height: 16), isCollapsed: true))
        XCTAssertEqual(caret(source)?.minX, 814)
    }

    /// Ghostty: nothing at all.
    func testNoAnswerIsNoCaret() {
        XCTAssertNil(caret(Source()))
        XCTAssertNil(caret(Source(selectedRange: CFRange(location: 3, length: 0))))
    }

    /// Lines wrap to the field only if its frame is around the caret.
    func testAFieldFrameMustHoldTheCaret() {
        let caret = CGRect(x: 300, y: 500, width: 0, height: 18)
        let field = CGRect(x: 100, y: 450, width: 600, height: 120)
        XCTAssertEqual(CaretLocator.frame(field, holding: caret), field)
        XCTAssertNil(CaretLocator.frame(nil, holding: caret))
        XCTAssertNil(CaretLocator.frame(.zero, holding: caret))
        XCTAssertNil(CaretLocator.frame(CGRect(x: 800, y: 450, width: 200, height: 120), holding: caret))
    }
}
