@testable import MurmurCloud
import XCTest

final class CloudTests: XCTestCase {
    private func frame(_ json: String) throws -> StreamEvent {
        try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
    }

    func testPCMIsFiniteClampedAndLittleEndian() throws {
        XCTAssertEqual(try CloudPolicy.pcm16([-2, 0, 1, 2]), Data([0, 128, 0, 0, 255, 127, 255, 127]))
        XCTAssertThrowsError(try CloudPolicy.pcm16([.nan]))
    }

    func testFinalRangeUsesServerAudioPositionsNotArrivalTime() throws {
        var content = CloudTranscript()
        try content.accept(frame("{\"type\":\"partial\",\"segment\":0,\"text\":\"draft\"}"), capturedSamples: 20000)
        try content.accept(frame("{\"type\":\"final\",\"segment\":0,\"text\":\"final\",\"start_sample\":1024,\"end_sample\":9000}"), capturedSamples: 90000)
        XCTAssertEqual(content.transcript.text, "final")
        XCTAssertEqual(content.transcript.utterances.first?.startSample, 1024)
        XCTAssertEqual(content.transcript.utterances.first?.endSample, 9000)
        XCTAssertEqual(content.provisional, "")
    }

    func testTranslationIsAttachedToItsFinalAndFailureKeepsOriginal() throws {
        var content = CloudTranscript()
        try content.accept(frame("{\"type\":\"final\",\"segment\":2,\"text\":\"original\",\"start_sample\":0,\"end_sample\":16000}"), capturedSamples: 16000)
        try content.accept(frame("{\"type\":\"translation\",\"segment\":2,\"translation\":\"translated\"}"), capturedSamples: 16000)
        XCTAssertEqual(content.transcript.translatedText, "translated")
        try content.accept(frame("{\"type\":\"translation_error\",\"segment\":2}"), capturedSamples: 16000)
        XCTAssertEqual(content.transcript.text, "original")
        XCTAssertEqual(content.transcript.translatedText, "")
        XCTAssertEqual(content.transcript.utterances.first?.translationFailed, true)
    }

    func testRepeatedFinalDoesNotDuplicateAPhrase() throws {
        var content = CloudTranscript()
        let event = try frame("{\"type\":\"final\",\"segment\":2,\"text\":\"words\",\"start_sample\":0,\"end_sample\":16000}")
        content.accept(event, capturedSamples: 16000); content.accept(event, capturedSamples: 16000)
        XCTAssertEqual(content.transcript.utterances.count, 1)
    }

    func testTranslationWithoutAFinalCannotOverwriteText() throws {
        var content = CloudTranscript()
        try content.accept(frame("{\"type\":\"translation\",\"segment\":9,\"translation\":\"orphan\"}"), capturedSamples: 16000)
        XCTAssertEqual(content.transcript.text, ""); XCTAssertEqual(content.transcript.translatedText, "")
    }

    func testStreamingDraftSurvivesStoppingBeforeAFinal() throws {
        var content = CloudTranscript()
        try content.accept(frame("{\"type\":\"fast\",\"text\":\"kept draft\"}"), capturedSamples: 16000)
        content.finish(samples: 16000)
        XCTAssertEqual(content.transcript.text, "kept draft")
        XCTAssertEqual(content.transcript.utterances.first?.endSample, 16000)
    }

    func testUnsetTariffDisablesTranslationWhileExplicitZeroEnablesIt() throws {
        func capabilities(enabled: Bool, textRate: Double?, mode: String = "separate") throws -> Capabilities {
            let json: [String: Any] = ["gatewayUrl": "https://example.com", "languages": ["ru"], "tiers": ["FAST", "QUALITY"],
                                       "creditsPerMinute": ["QUALITY": 8], "maxAudioSeconds": 600, "maxUploadBytes": 10000, "readyTimeoutSeconds": 240,
                                       "purchaseChannel": "web", "translation": ["version": 1, "enabled": enabled, "pairs": [["source": "ru", "target": "en"]],
                                                                                 "textCreditsPer1000": textRate.map { $0 as Any } ?? NSNull(), "transcriptMode": mode,
                                                                                 "transcriptCreditsPer1000": NSNull(), "maxInputChars": 2000, "maxOutputChars": 4000, "timeoutSeconds": 60]]
            return try JSONDecoder().decode(Capabilities.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(try CloudPolicy.translationTargets(capabilities(enabled: true, textRate: nil), source: "ru").isEmpty)
        XCTAssertEqual(try CloudPolicy.translationTargets(capabilities(enabled: true, textRate: 0), source: "ru"), ["en"])
        XCTAssertTrue(try CloudPolicy.translationTargets(capabilities(enabled: false, textRate: 0), source: "ru").isEmpty)
        XCTAssertTrue(try CloudPolicy.translationTargets(capabilities(enabled: true, textRate: 0), source: "ru", transcript: true).isEmpty)
        XCTAssertEqual(try CloudPolicy.translationTargets(capabilities(enabled: true, textRate: nil, mode: "included"), source: "ru", transcript: true), ["en"])
    }
}
