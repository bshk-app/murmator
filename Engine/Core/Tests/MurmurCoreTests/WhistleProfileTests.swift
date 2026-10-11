import XCTest
@testable import MurmurCore

final class WhistleProfileTests: XCTestCase {
    func testWhistleRequiresExplicitEnglishFastOnMac() throws {
        let baseline = try SpeechRecognitionProfile.resolve(language: "en", mode: .fast)
        let candidate = try SpeechRecognitionProfile.resolve(language: "en", mode: .fast, previewBackend: .whistle)
        #if os(macOS)
        XCTAssertEqual(candidate.previewBackend, .whistle)
        XCTAssertEqual(candidate.previewStage, "whistle-swift-cpu")
        XCTAssertNotEqual(candidate.configurationID, baseline.configurationID)
        #else
        XCTAssertEqual(candidate.previewBackend, .nemotron)
        #endif
        XCTAssertEqual(baseline.previewBackend, .nemotron)
        for language in ["auto", "ru", "fi", "de", "fr", "ar"] {
            XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: language, mode: .fast, previewBackend: .whistle).previewBackend, .nemotron)
        }
        for mode in [DictationMode.accurate, .hybrid] {
            XCTAssertEqual(try SpeechRecognitionProfile.resolve(language: "en", mode: mode, previewBackend: .whistle).previewBackend, .nemotron)
        }
        XCTAssertNil(candidate.finalStage)
    }
}
