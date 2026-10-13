import AppKit
import XCTest
@testable import MurmurCaptions

/// Exercise the actual TextKit layout and animated viewport, not a second
/// implementation of wrapping or a test of animation constants.
@MainActor
final class CaptionsScrollingTests: XCTestCase {
    private func makeView(lines: Int = 2) -> CaptionsTextView {
        let height = CaptionsLayout.trackHeight(lines: lines, size: 30)
        let view = CaptionsTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        view.reduceMotion = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func lines(in view: CaptionsTextView) -> [String] {
        let manager = view.textView.layoutManager!
        let container = view.textView.textContainer!
        manager.ensureLayout(for: container)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, range, _ in
            let chars = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            lines.append((view.textView.string as NSString).substring(with: chars))
        }
        return lines
    }

    func testAddingWordsDoesNotRewrapExistingCompleteLines() {
        let view = makeView()
        var text = (0..<150).map { "слово\($0)" }.joined(separator: " ")
        view.update(confirmed: text, partial: "", size: 30, color: .white)
        let original = Array(lines(in: view).dropLast())
        for word in ["добавление", "ещё", "несколько", "новых", "слов"] {
            text += " " + word
            view.update(confirmed: text, partial: "", size: 30, color: .white)
            XCTAssertEqual(Array(lines(in: view).prefix(original.count)), original)
        }
    }

    func testTranslationKeepsItsLineBreaksWhenAnotherSentenceArrives() {
        let view = makeView(lines: 1)
        let text = String(repeating: "A translated sentence stays in place. ", count: 20)
        view.update(confirmed: text, partial: "", size: 30, color: .yellow)
        let original = Array(lines(in: view).dropLast())
        view.update(confirmed: text + "The next sentence.", partial: "", size: 30, color: .yellow)
        XCTAssertEqual(Array(lines(in: view).prefix(original.count)), original)
    }

    func testDraftPromotionChangesColorWithoutMovingText() throws {
        let view = makeView()
        let confirmed = "Привет 👩🏽‍💻"
        let partial = "мир é"
        view.update(confirmed: confirmed, partial: partial, size: 30, color: .white)
        let before = lines(in: view)
        let position = view.clipView.bounds.origin
        let index = (confirmed as NSString).length + 1
        let draft = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(draft.alphaComponent, 0.72, accuracy: 0.001)
        view.update(confirmed: confirmed + " " + partial, partial: "", size: 30, color: .white)
        XCTAssertEqual(lines(in: view), before)
        XCTAssertEqual(view.clipView.bounds.origin, position)
        let final = try XCTUnwrap(view.textView.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(final.alphaComponent, 1)
        view.update(confirmed: confirmed, partial: "мир 👨‍👩‍👧‍👦", size: 30, color: .white)
        XCTAssertEqual(view.textView.string, confirmed + " мир 👨‍👩‍👧‍👦")
        for partial in ["e\u{301}", "é", "e", "e\u{301}", "👩", "👩🏽‍💻"] {
            view.update(confirmed: confirmed, partial: partial, size: 30, color: .white)
            XCTAssertEqual(Array(view.textView.string.utf16), Array((confirmed + " " + partial).utf16))
        }
    }

    func testAccurateCorrectionsPreserveMatchingTextAndTheNewerFastDraft() throws {
        let view = makeView(lines: 3)
        let draft = "этот мальчик показывает как работает приложение и потом включает перевод"
        let accurate = "Этот мальчик показывает, как работает приложение, и затем включает перевод."
        let newerDraft = "Дальше мы проверяем субтитры"
        view.update(confirmed: draft, partial: newerDraft, size: 25, color: .white)
        let storage = try XCTUnwrap(view.textView.textStorage)
        let anchor = NSAttributedString.Key("test.readingAnchor")
        for phrase in ["работает приложение", newerDraft] {
            storage.addAttribute(anchor, value: phrase, range: (storage.string as NSString).range(of: phrase))
        }
        view.update(confirmed: accurate, partial: newerDraft, size: 25, color: .white)
        XCTAssertEqual(storage.string, accurate + " " + newerDraft)
        for phrase in ["работает приложение", newerDraft] {
            let range = (storage.string as NSString).range(of: phrase)
            XCTAssertEqual(storage.attribute(anchor, at: range.location, effectiveRange: nil) as? String, phrase,
                           "matching text must survive in storage, not be deleted and reinserted")
        }
        let draftStart = (storage.string as NSString).range(of: newerDraft).location
        let color = try XCTUnwrap(storage.attribute(.foregroundColor, at: draftStart, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.alphaComponent, 0.72, accuracy: 0.001)
    }

    func testOverflowScrollsThroughIntermediatePositions() {
        let view = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.reduceMotion = false
        view.update(confirmed: "Первая строка", partial: "", size: 30, color: .white)
        let before = view.clipView.bounds.minY
        let text = (0..<40).map { "слово\($0)" }.joined(separator: " ")
        view.update(confirmed: text, partial: "", size: 30, color: .white)
        let destination = view.textView.frame.height - view.bounds.height
        XCTAssertGreaterThan(destination, before)
        XCTAssertEqual(view.clipView.bounds.minY, before, accuracy: 0.5, "must not jump directly to the destination")
        var intermediate = false
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let y = view.clipView.bounds.minY
            if y > before + 0.5 && y < destination - 0.5 { intermediate = true }
        }
        XCTAssertTrue(intermediate, "the visible viewport must move smoothly")
        XCTAssertEqual(view.clipView.bounds.minY, destination, accuracy: 0.5)
    }

    func testReducedMotionResizeAndClearKeepTheLatestTextVisible() {
        let view = makeView()
        let text = String(repeating: "Длинный текст с переносами. ", count: 80)
        view.update(confirmed: text, partial: "", size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)
        view.setFrameSize(CGSize(width: 400, height: view.frame.height))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)
        view.update(confirmed: "", partial: "", size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.minY, 0)
        XCTAssertEqual(view.textView.string, "…")
    }

    func testAShorterCorrectionDoesNotClampTheViewportBeforeAnimating() {
        let view = makeView()
        let text = String(repeating: "Длинный черновик распознавания. ", count: 30)
        view.update(confirmed: "Начало.", partial: text, size: 30, color: .white)
        let before = view.clipView.bounds.minY
        view.reduceMotion = false
        view.update(confirmed: "Начало.", partial: String(text.prefix(text.count - 150)), size: 30, color: .white)
        XCTAssertEqual(view.clipView.bounds.minY, before, accuracy: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertLessThan(view.clipView.bounds.minY, before)
        XCTAssertEqual(view.clipView.bounds.maxY, view.textView.frame.height, accuracy: 0.5)

        // A restart must cancel the earlier movement, including its completion.
        view.update(confirmed: "Начало.", partial: text, size: 30, color: .white)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.update(confirmed: "", partial: "", size: 30, color: .white)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(view.clipView.bounds.minY, 0)
        XCTAssertEqual(view.textView.frame.height, view.bounds.height)
    }

    func testFontAndColorsUpdateAlreadyVisibleText() throws {
        let view = CaptionsTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 140))
        view.layoutSubtreeIfNeeded()
        view.update(confirmed: "Readable text", partial: "", size: 25, color: .white)
        view.update(confirmed: "Readable text", partial: "", size: 34, color: .cyan, family: "Menlo")
        let storage = try XCTUnwrap(view.textView.textStorage)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 34)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .cyan)
    }
}

final class CaptionsTextDiffTests: XCTestCase {
    private func apply(_ edits: [CaptionsTextEdit], to old: String) -> String {
        let result = NSMutableString(string: old)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    func testSeparatedCorrectionsProduceSeparateEdits() {
        let old = "Этот малчик показывает как работает приложение и потом включает перевод"
        let new = "Этот мальчик показывает, как работает приложение и затем включает перевод."
        let edits = CaptionsTextDiff.edits(from: old, to: new)
        let unchanged = (old as NSString).range(of: "как работает приложение")
        XCTAssertGreaterThanOrEqual(edits.count, 3)
        for edit in edits { XCTAssertEqual(NSIntersectionRange(edit.range, unchanged).length, 0) }
        XCTAssertEqual(apply(edits, to: old), new)
    }

    func testAppendingPromotingClearingAndReplacingUnicode() {
        let examples: [(String, String)] = [
            ("", "Начало"), ("Начало", "Начало продолжение"), ("готово", "готово"), ("готово", ""),
            ("cafe\u{301} 👩🏽‍💻", "café 👨‍👩‍👧‍👦"), ("e", "e\u{301}"),
            ("你好吗世界", "你好，世界！"), ("one\nunchanged\nthree", "One\nunchanged\nThree"),
            (String(repeating: "а", count: 5000), String(repeating: "б", count: 5000)),
        ]
        for (old, new) in examples {
            let edits = CaptionsTextDiff.edits(from: old, to: new)
            XCTAssertEqual(Array(apply(edits, to: old).utf16), Array(new.utf16))
        }
        XCTAssertTrue(CaptionsTextDiff.edits(from: "готово", to: "готово").isEmpty)
    }

    func testMixedEditsReconstructTheExactAuthoritativeText() {
        // Pinned pseudo-random stream includes repeats, punctuation and multi-unit
        // graphemes; catches offset drift when several insertions/deletions mix.
        var seed: UInt64 = 42
        func next(_ upper: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        let alphabet = ["а", "б", " ", ",", "👩🏽‍💻", "e\u{301}", "é", "你", "\n"]
        for _ in 0..<200 {
            let old = (0..<30).map { _ in alphabet[next(alphabet.count)] }
            var new = old
            for _ in 0..<6 {
                let index = next(new.count)
                switch next(3) {
                case 0: new.remove(at: index)
                case 1: new.insert(alphabet[next(alphabet.count)], at: index)
                default: new[index] = alphabet[next(alphabet.count)]
                }
            }
            let a = old.joined(), b = new.joined()
            XCTAssertEqual(Array(apply(CaptionsTextDiff.edits(from: a, to: b), to: a).utf16), Array(b.utf16))
        }
    }
}
