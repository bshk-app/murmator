import XCTest
@testable import MurmurCore

final class PreparationAndLanguageTests: XCTestCase {
    func testBackgroundCancellationCannotEraseTheResumeRequest() {
        var state = PreparationResumePolicy()
        let old = state.begin("speech:fi")
        XCTAssertTrue(state.pause())
        state.complete(old)
        XCTAssertEqual(state.resumableRequest(isActive: true, isBusy: false), "speech:fi")
        XCTAssertNil(state.resumableRequest(isActive: false, isBusy: false))
        XCTAssertNil(state.resumableRequest(isActive: true, isBusy: true))
        let resumed = state.begin("speech:fi")
        state.complete(old)
        XCTAssertEqual(state.request, "speech:fi")
        state.complete(resumed)
        XCTAssertNil(state.request)
    }
    func testExplicitCancelDoesNotRestartOnForeground() {
        var state = PreparationResumePolicy(savedRequest: "all")
        state.cancel()
        XCTAssertNil(state.resumableRequest(isActive: true, isBusy: false))
    }
    func testProgressDoesNotRestartAtModelOrLanguageBoundaries() {
        XCTAssertEqual(PreparationProgress.fraction(step: 0, steps: 2, current: 1), 0.5)
        XCTAssertEqual(PreparationProgress.fraction(step: 1, steps: 2, current: 0), 0.5)
        XCTAssertEqual(PreparationProgress.fraction(step: 1, steps: 2, current: 1, batch: 0, batches: 2), 0.5)
        XCTAssertEqual(PreparationProgress.fraction(step: 0, steps: 2, current: 0, batch: 1, batches: 2), 0.5)
    }
    func testDownloadedDirectionsArePromotedWithoutInventingReversePacks() {
        let routes = OfflineTranslationRoutes(pairs: [.init(source: "fi", target: "en"), .init(source: "en", target: "ru")])
        // FI→RU selects its registered direct model; two other installed legs
        // must not silently change the selected quality profile.
        XCTAssertEqual(routes.targets(from: "fi"), ["en"])
        XCTAssertEqual(routes.targets(from: "ru"), [])
        XCTAssertEqual(routes.sources, ["en", "fi"], "only installed directions offer a source")
    }
    func testSharedSpeechModelListsEnglishAndFinnish() {
        XCTAssertEqual(SpeechModelChoice.languages(forStorageID: "speech/multilingual-accurate", selected: ["ru", "en", "fi"]), ["ru", "en", "fi"])
        XCTAssertEqual(SpeechModelChoice.languages(forStorageID: "speech/russian-accurate", selected: ["ru", "en", "fi"]), ["ru"])
    }
}
