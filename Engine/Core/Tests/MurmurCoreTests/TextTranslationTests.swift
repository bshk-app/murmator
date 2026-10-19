import XCTest
@testable import MurmurCore

private actor TextEngineProbe: TextTranslationEngine {
    enum Failure: Error { case download }
    let blocked: Bool
    let fails: Bool
    var requests: [(String, String, String)] = []
    var unloaded = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var translating = false
    init(blocked: Bool = false, fails: Bool = false) { self.blocked = blocked; self.fails = fails }
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        if fails { throw Failure.download }
        await onProgress(1)
    }
    func translate(_ text: String, from: String, to: String) async throws -> String {
        requests.append((text, from, to)); translating = true
        startedWaiters.forEach { $0.resume() }; startedWaiters.removeAll()
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return "Translated: " + text
    }
    func waitForTranslation() async { if !translating { await withCheckedContinuation { startedWaiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
    var residentModelCount: Int { unloaded ? 0 : 1 }
    func unload() async { unloaded = true }
}
@MainActor final class TextTranslationTests: XCTestCase {
    private func model(_ engine: TextEngineProbe) -> TextTranslationModel {
        .init(engine: engine, source: "ru", target: "fi", availableTargets: { from in ["ru", "fi", "en"].filter { $0 != from } })
    }
    func testTranslationAndSwapUseMatchingTextAndLanguages() async throws {
        let engine = TextEngineProbe()
        let actual = model(engine)
        actual.input = "First paragraph.\n\nSecond paragraph."
        await actual.start()?.value
        XCTAssertEqual(actual.output, "Translated: " + actual.input)
        let calls = await engine.requests
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].1, "ru"); XCTAssertEqual(calls[0].2, "fi")
        let translated = actual.output
        actual.swap()
        XCTAssertEqual(actual.source, "fi"); XCTAssertEqual(actual.target, "ru")
        XCTAssertEqual(actual.input, translated); XCTAssertTrue(actual.output.isEmpty)
        XCTAssertTrue(actual.modelsLoaded)
        await actual.unload(); XCTAssertFalse(actual.modelsLoaded)
    }
    func testEditingDuringAnUncooperativeTranslationDiscardsStaleOutputAndSerializesRequests() async {
        let engine = TextEngineProbe(blocked: true)
        let actual = model(engine)
        actual.input = "Old text"
        let running = actual.start()
        await engine.waitForTranslation()
        actual.input = "New text"
        XCTAssertEqual(actual.phase, .cancelling)
        XCTAssertNil(actual.start(), "Do not overlap a still-running native translation")
        await engine.release(); await running?.value
        XCTAssertEqual(actual.input, "New text"); XCTAssertTrue(actual.output.isEmpty)
        XCTAssertNil(actual.error); XCTAssertFalse(actual.isBusy)
        let unloaded = await engine.unloaded
        XCTAssertTrue(unloaded)
    }
    func testFailureKeepsOriginalAndAllowsRetry() async {
        let sut = model(TextEngineProbe(fails: true))
        sut.input = "Keep my text"
        await sut.start()?.value
        XCTAssertEqual(sut.input, "Keep my text"); XCTAssertTrue(sut.output.isEmpty)
        XCTAssertNotNil(sut.error); XCTAssertTrue(sut.canTranslate); XCTAssertFalse(sut.modelsLoaded)
    }
    func testExplicitCancelNeverPublishesLateResult() async {
        let engine = TextEngineProbe(blocked: true)
        let actual = model(engine); actual.input = "Keep my text"
        let running = actual.start(); await engine.waitForTranslation(); actual.cancel()
        await engine.release(); await running?.value
        XCTAssertEqual(actual.input, "Keep my text"); XCTAssertTrue(actual.output.isEmpty)
        XCTAssertFalse(actual.isBusy); XCTAssertNil(actual.error)
    }
    func testBlankOversizedAndUnsupportedInputCannotStart() {
        let sut = model(TextEngineProbe()); sut.input = "  \n"
        XCTAssertNil(sut.start())
        sut.input = String(repeating: "a", count: TextTranslationModel.characterLimit + 1)
        XCTAssertNil(sut.start())
        sut.input = "Hello"; sut.setSource("fi")
        XCTAssertNotEqual(sut.source, sut.target)
        let unsupported = TextTranslationModel(engine: TextEngineProbe(), source: "xx", target: "fi", availableTargets: { _ in [] })
        unsupported.input = "Hello"
        XCTAssertNil(unsupported.start()); XCTAssertFalse(unsupported.canSwap)
    }
    func testChangingLanguagesInvalidatesPreviousResult() async {
        let sut = model(TextEngineProbe()); sut.input = "Hello"
        await sut.start()?.value
        XCTAssertFalse(sut.output.isEmpty)
        sut.setTarget("en")
        XCTAssertTrue(sut.output.isEmpty); XCTAssertEqual(sut.input, "Hello")
    }
    func testServiceLimitCountsUnicodeCodePointsInsteadOfGraphemes() {
        let sut = TextTranslationModel(engine: TextEngineProbe(), source: "ru", target: "fi",
            availableTargets: { _ in ["fi"] }, maximumCharacters: 2)
        sut.input = "e\u{301}"
        XCTAssertEqual(sut.input.count, 1)
        XCTAssertEqual(sut.inputCharacters, 2)
        XCTAssertTrue(sut.canTranslate)
        sut.input += "!"
        XCTAssertFalse(sut.canTranslate)
        XCTAssertNil(sut.start())
    }
}
