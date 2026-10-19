@testable import MurmurCore
import XCTest
@testable import MurmurKit

/// Counts every call, so "did this phrase get translated again?" is answerable.
private actor SpyTranslator: PhraseTranslating {
    private(set) var calls: [String] = []
    private var replies: [String: String] = [:]
    private var unavailable: Set<String> = []

    func reply(_ translation: String, for source: String) {
        unavailable.remove(source)
        replies[source] = translation
    }
    func fail(_ source: String) { unavailable.insert(source) }
    func log() -> [String] { calls }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        calls.append(text)
        if unavailable.contains(text) { throw URLError(.fileDoesNotExist) }
        return replies[text] ?? "<\(text)>"
    }

    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String {
        (try? await translate(text, from: source, to: target)) ?? ""
    }
}

/// Holds one engine result across reset without relying on cancellation or timing.
private actor LanguagePairTranslator: PhraseTranslating {
    private var calls: [String] = []
    private var onSuspend: (@Sendable () -> Void)?
    private var suspended: CheckedContinuation<Void, Never>?

    init(onSuspend: (@Sendable () -> Void)? = nil) {
        self.onSuspend = onSuspend
    }

    func log() -> [String] { calls }
    func resume() {
        suspended?.resume()
        suspended = nil
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let result = "\(source)-\(target):\(text)"
        calls.append(result)
        if let onSuspend {
            self.onSuspend = nil
            await withCheckedContinuation { continuation in
                suspended = continuation
                onSuspend()
            }
        }
        return result
    }

    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String {
        (try? await translate(text, from: source, to: target)) ?? ""
    }
}

final class CaptionTranslatorTests: XCTestCase {
    private func segment(_ id: UInt64, _ text: String) -> CaptionSegment {
        CaptionSegment(id: id, startSample: 0, endSample: 1, text: text, state: .confirmed)
    }

    /// The reason this type exists. Captions emit a snapshot several times a
    /// second; translating the whole transcript each time would re-translate
    /// every sentence hundreds of times over a talk.
    func testAnUnchangedPhraseIsTranslatedOnlyOnce() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        let segments = [segment(1, "привет"), segment(2, "как дела")]

        for _ in 0..<25 {
            _ = await translator.translation(of: segments, from: "ru", to: "en")
        }

        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "как дела"],
                       "phrases were re-translated on later snapshots")
    }

    /// The batch pass rewrites a phrase in place. Keying the cache on the id
    /// alone would keep showing the translation of text that no longer exists.
    func testACorrectedPhraseIsTranslatedAgain() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        _ = await translator.translation(of: [segment(1, "как дила")], from: "ru", to: "en")
        let line = await translator.translation(of: [segment(1, "как дела")], from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["как дила", "как дела"])
        XCTAssertEqual(line, "<как дела>", "the stale translation survived a correction")
    }

    func testPhrasesAreJoinedInTranscriptOrder() async {
        let spy = SpyTranslator()
        await spy.reply("one", for: "раз")
        await spy.reply("two", for: "два")
        let translator = CaptionTranslator(service: spy)

        let line = await translator.translation(
            of: [segment(1, "раз"), segment(2, "два")], from: "ru", to: "en")
        XCTAssertEqual(line, "one two")
    }

    /// Nothing closed yet reads on screen as a HUD with no second line, rather
    /// than an empty one under a hairline.
    func testNothingConfirmedGivesNoLine() async {
        let translator = CaptionTranslator(service: SpyTranslator())
        let line = await translator.translation(of: [], from: "ru", to: "en")
        XCTAssertTrue(line.isEmpty)
    }

    func testBlankPhrasesAreSkipped() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        _ = await translator.translation(
            of: [segment(1, "   "), segment(2, "текст")], from: "ru", to: "en")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["текст"], "whitespace was sent to the engine")
    }

    /// A talk can run for an hour; the cache must not grow with every phrase
    /// the transcript has already dropped.
    func testDroppedPhrasesAreForgotten() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        _ = await translator.translation(of: [segment(1, "первое")], from: "ru", to: "en")
        // Segment 1 scrolls out of the transcript, then its id is seen again
        // with different text — a stale entry would answer for it.
        _ = await translator.translation(of: [segment(2, "второе")], from: "ru", to: "en")
        _ = await translator.translation(of: [segment(1, "первое")], from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["первое", "второе", "первое"])
    }

    /// Realtime: the live tail is translated too, so the second line moves with
    /// the speaker instead of waiting for the phrase to close.
    func testTheLiveDraftIsTranslated() async {
        let spy = SpyTranslator()
        await spy.reply("hello", for: "привет")
        await spy.reply("how are", for: "как де")
        let translator = CaptionTranslator(service: spy)

        let line = await translator.translation(
            of: [segment(1, "привет")], draft: "как де", from: "ru", to: "en")
        XCTAssertEqual(line, "hello how are")
    }

    /// The draft is re-emitted far more often than it changes wording; an
    /// uncached tail would re-translate the same string many times a second.
    func testAnUnchangedDraftIsNotRetranslated() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        for _ in 0..<10 {
            _ = await translator.translation(of: [], draft: "как дела", from: "ru", to: "en")
        }
        let calls = await spy.log()
        XCTAssertEqual(calls, ["как дела"], "the live tail was re-translated while unchanged")
    }

    /// As the speaker carries on, each new wording is translated once.
    func testAGrowingDraftIsTranslatedPerWording() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)

        for tail in ["как", "как де", "как дела"] {
            _ = await translator.translation(of: [], draft: tail, from: "ru", to: "en")
        }
        let calls = await spy.log()
        XCTAssertEqual(calls, ["как", "как де", "как дела"])
    }

    /// Omitting the draft keeps the old behaviour: settled phrases only.
    func testWithoutADraftOnlyConfirmedPhrasesAreTranslated() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        _ = await translator.translation(of: [segment(1, "привет")], from: "ru", to: "en")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет"])
    }

    func testResetClearsEverything() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        let segments = [segment(1, "привет")]

        _ = await translator.translation(of: segments, from: "ru", to: "en")
        await translator.reset()
        _ = await translator.translation(of: segments, from: "ru", to: "en")

        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "привет"], "a new talk inherited the old cache")
    }

    func testResetDiscardsAnInFlightPhraseAndStopsTheOldTranscript() async {
        let suspended = expectation(description: "old phrase is in flight")
        let engine = LanguagePairTranslator { suspended.fulfill() }
        let translator = CaptionTranslator(service: engine)
        let segments = [segment(1, "привет"), segment(2, "пока")]
        let old = Task {
            await translator.translation(of: segments, from: "ru", to: "en")
        }
        await fulfillment(of: [suspended], timeout: 2)

        await translator.reset()
        await engine.resume()
        let discarded = await old.value
        XCTAssertEqual(discarded, "", "a reset talk returned stale output")
        let oldCalls = await engine.log()
        XCTAssertEqual(oldCalls, ["ru-en:привет"], "the reset talk kept translating")

        let fresh = await translator.translation(of: segments, from: "ru", to: "en")
        XCTAssertEqual(fresh, "ru-en:привет ru-en:пока")
        let calls = await engine.log()
        XCTAssertEqual(calls, ["ru-en:привет", "ru-en:привет", "ru-en:пока"],
                       "the old phrase repopulated the reset cache")
    }

    func testResetDiscardsAnInFlightDraft() async {
        let suspended = expectation(description: "old draft is in flight")
        let engine = LanguagePairTranslator { suspended.fulfill() }
        let translator = CaptionTranslator(service: engine)
        let old = Task {
            await translator.translation(of: [], draft: "привет", from: "ru", to: "en")
        }
        await fulfillment(of: [suspended], timeout: 2)

        await translator.reset()
        await engine.resume()
        let discarded = await old.value
        XCTAssertEqual(discarded, "", "a reset talk returned its old draft")
        let fresh = await translator.translation(of: [], draft: "привет", from: "ru", to: "en")
        XCTAssertEqual(fresh, "ru-en:привет")
        let calls = await engine.log()
        XCTAssertEqual(calls, ["ru-en:привет", "ru-en:привет"],
                       "the old draft repopulated the reset cache")
    }

    func testCancelledTranslationCannotPopulatePhraseOrDraftCache() async {
        for translatingDraft in [false, true] {
            let suspended = expectation(description: "cancelled translation is in flight")
            let engine = LanguagePairTranslator { suspended.fulfill() }
            let translator = CaptionTranslator(service: engine)
            let segments = translatingDraft ? [] : [segment(1, "привет")]
            let draft = translatingDraft ? "привет" : ""
            let old = Task {
                await translator.translation(of: segments, draft: draft, from: "ru", to: "en")
            }
            await fulfillment(of: [suspended], timeout: 2)

            old.cancel()
            await engine.resume()
            let discarded = await old.value
            XCTAssertEqual(discarded, "")
            let fresh = await translator.translation(of: segments, draft: draft, from: "ru", to: "en")
            XCTAssertEqual(fresh, "ru-en:привет")
            let calls = await engine.log()
            XCTAssertEqual(calls, ["ru-en:привет", "ru-en:привет"])
        }
    }

    func testTargetLanguageIsPartOfPhraseAndDraftCacheIdentity() async {
        let engine = LanguagePairTranslator()
        let translator = CaptionTranslator(service: engine)
        let segments = [segment(1, "привет")]

        let english = await translator.translation(of: segments, draft: "пока", from: "ru", to: "en")
        XCTAssertEqual(english, "ru-en:привет ru-en:пока")
        for _ in 0..<3 {
            let german = await translator.translation(of: segments, draft: "пока", from: "ru", to: "de")
            XCTAssertEqual(german, "ru-de:привет ru-de:пока", "the selected language used another pair's cache")
        }

        let calls = await engine.log()
        XCTAssertEqual(calls, ["ru-en:привет", "ru-en:пока", "ru-de:привет", "ru-de:пока"],
                       "each language pair must translate once and then reuse its result")
    }

    func testSourceLanguageIsPartOfPhraseAndDraftCacheIdentity() async {
        let engine = LanguagePairTranslator()
        let translator = CaptionTranslator(service: engine)
        let segments = [segment(1, "hello")]

        _ = await translator.translation(of: segments, draft: "world", from: "ru", to: "en")
        for _ in 0..<3 {
            let result = await translator.translation(of: segments, draft: "world", from: "fi", to: "en")
            XCTAssertEqual(result, "fi-en:hello fi-en:world")
        }

        let calls = await engine.log()
        XCTAssertEqual(calls, ["ru-en:hello", "ru-en:world", "fi-en:hello", "fi-en:world"])
    }

    func testUnavailableModelDoesNotCacheAConfirmedPhrase() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        let segments = [segment(1, "привет")]
        await spy.fail("привет")

        let missing = await translator.translation(of: segments, from: "ru", to: "en")
        XCTAssertEqual(missing, "")
        await spy.reply("hello", for: "привет")
        let recovered = await translator.translation(of: segments, from: "ru", to: "en")

        XCTAssertEqual(recovered, "hello")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "привет"])
    }

    func testUnavailableModelDoesNotCacheTheDraft() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        await spy.fail("привет")

        let missing = await translator.translation(of: [], draft: "привет", from: "ru", to: "en")
        XCTAssertEqual(missing, "")
        await spy.reply("hello", for: "привет")
        let recovered = await translator.translation(of: [], draft: "привет", from: "ru", to: "en")

        XCTAssertEqual(recovered, "hello")
        let calls = await spy.log()
        XCTAssertEqual(calls, ["привет", "привет"])
    }

    func testSuccessfulEmptyTranslationsAreCachedForPhrasesAndDrafts() async {
        let spy = SpyTranslator()
        let translator = CaptionTranslator(service: spy)
        await spy.reply("", for: "фраза")
        await spy.reply("", for: "хвост")

        for _ in 0..<3 {
            let result = await translator.translation(of: [segment(1, "фраза")], draft: "хвост", from: "ru", to: "en")
            XCTAssertEqual(result, "")
        }

        let calls = await spy.log()
        XCTAssertEqual(calls, ["фраза", "хвост"])
    }

    func testTranslationServiceRecoversWhenTheModelIsInstalled() async throws {
        guard let installed = bergamotModels?.appendingPathComponent("moz-ruen"),
              FileManager.default.fileExists(atPath: installed.appendingPathComponent("config.bergamot.yml").path) else {
            throw XCTSkip("ru-en model not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TranslationService(modelsRoot: root)
        let translator = CaptionTranslator(service: service)
        let segments = [segment(1, "Я пришлю документы завтра.")]

        let missing = await translator.translation(of: segments, from: "ru", to: "en")
        XCTAssertEqual(missing, "")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("moz-ruen"), withDestinationURL: installed)
        let recovered = await translator.translation(of: segments, from: "ru", to: "en")

        XCTAssertTrue(recovered.lowercased().contains("tomorrow"), recovered)
        let resident = await service.residentPairs
        XCTAssertEqual(resident.count, 1)
    }
}
