import Foundation
import XCTest
import MurmurCore
@testable import MurmurSession

@MainActor final class TranscriptPostProcessorTests: XCTestCase {
    func testWarmCloudEditingKeepsDetectorUntilExplicitUnload() async throws {
        let detector = FakeLanguageDetector(), editor = FakeTextEditor()
        let processor = SessionPostProcessor(detector: detector, editor: editor, keepDetectorWarm: true)
        try await processor.prepare(progress: { _ in })
        for _ in 0..<2 {
            _ = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: transcript(), modelID: nil)
            await processor.releaseDetector()
        }
        XCTAssertEqual(detector.closeCount, 0, "preloaded cloud editing must not reload Whisper every take")
        await processor.close()
        XCTAssertEqual(detector.closeCount, 1, "Unload still releases the detector")
    }
    private func transcript() -> RecordingTranscript {
        var value = RecordingTranscript()
        value.appendSettled(.init(id: 7, startSample: 123, endSample: 16_000, text: "hello there"))
        value.appendSettled(.init(id: 8, startSample: 16_000, endSample: 32_000, text: "bye now"))
        value.finish(fallback: "", endSample: 32_000)
        return value
    }
    func testProviderReceivesWhisperLanguageAndTheWholeFinalTranscript() async throws {
        let detector = FakeLanguageDetector(), editor = FakeTextEditor()
        let processor = SessionPostProcessor(detector: detector, editor: editor)
        let original = transcript()
        let result = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: "remote-or-local-model")
        let requests = await editor.requests
        XCTAssertEqual(requests.map(\.language), ["fi"])
        XCTAssertEqual(requests.map(\.text), ["hello there bye now"])
        XCTAssertEqual(requests.first?.modelID, "remote-or-local-model")
        XCTAssertEqual(result?.language, "fi")
        XCTAssertEqual(result?.transcript.utterances.map(\.id), [7, 8])
        XCTAssertEqual(result?.transcript.utterances.first?.startSample, 123)
        XCTAssertEqual(original.text, "hello there bye now")
        XCTAssertEqual(detector.closeCount, 1)
        XCTAssertEqual(detector.prepareCount, 1)
    }
    func testFailureInLaterSectionDoesNotCommitPartialEdits() async throws {
        let detector = FakeLanguageDetector(), editor = FakeTextEditor(failAfter: 1)
        let processor = SessionPostProcessor(detector: detector, editor: editor)
        var original = RecordingTranscript()
        original.appendSettled(.init(id: 1, startSample: 0, endSample: 32_000,
            text: String(repeating: "hello there. bye now. ", count: 200)))
        original.finish(fallback: "", endSample: 32_000)
        let originalText = original.text
        do {
            _ = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
            XCTFail("partial edit was returned")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadCorruptFile) }
        XCTAssertEqual(original.text, originalText)
    }
    func testNoSpeechDoesNotInvokeTheTextProvider() async throws {
        let detector = FakeLanguageDetector(), editor = FakeTextEditor()
        detector.language = nil
        let processor = SessionPostProcessor(detector: detector, editor: editor)
        let result = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: transcript(), modelID: nil)
        let requests = await editor.requests
        XCTAssertNil(result)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRejectedCandidateKeepsTheOriginalAndTheNextRunStillEdits() async throws {
        let detector = FakeLanguageDetector(), editor = RejectingTextEditor()
        let processor = SessionPostProcessor(detector: detector, editor: editor)
        let original = transcript()
        let first = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
        XCTAssertEqual(first?.transcript.text, original.text)
        XCTAssertNil(first?.modelID)
        await processor.close()
        let second = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
        XCTAssertEqual(second?.transcript.text, "Hello There Bye Now.")
    }

    func testUnsafeNumbersDeclineTheWholeOrdinaryDictation() async throws {
        var original = RecordingTranscript()
        original.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000, text: "Встреча в 18:30"))
        original.appendSettled(.init(id: 2, startSample: 16_000, endSample: 32_000, text: "до завтра"))
        original.finish(fallback: "", endSample: 32_000)
        let processor = SessionPostProcessor(detector: FakeLanguageDetector(), editor: ChangingNumbersEditor())
        let result = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
        XCTAssertEqual(result?.transcript.text, original.text)
        XCTAssertEqual(result?.transcript.utterances.map(\.id), [1, 2])
        XCTAssertNil(result?.modelID)
        XCTAssertEqual(original.text, "Встреча в 18:30 до завтра")
    }

    func testSentenceSplitByRecognitionIsEditedWithBothHalvesTogether() async throws {
        var original = RecordingTranscript()
        var first = RecordedUtterance(id: 7, startSample: 123, endSample: 16_000,
                                     text: "Макеты будут готовы к пятнице после")
        first.sourceName = "RODE"
        original.appendSettled(first)
        original.appendSettled(.init(id: 8, startSample: 16_000, endSample: 32_000,
                                     text: "Этого начнём верстку."))
        original.finish(fallback: "", endSample: 32_000)
        let corrected = "Макеты будут готовы к пятнице. После этого начнём вёрстку."
        let editor = WholeSentenceEditor(corrected)
        let processor = SessionPostProcessor(detector: FakeLanguageDetector(), editor: editor)
        let result = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
        let requests = await editor.inputs
        XCTAssertEqual(requests, [original.text])
        XCTAssertEqual(result?.transcript.text, corrected)
        XCTAssertEqual(result?.transcript.utterances.map(\.id), [7, 8])
        XCTAssertEqual(result?.transcript.utterances.map(\.startSample), [123, 16_000])
        XCTAssertEqual(result?.transcript.utterances.map(\.endSample), [16_000, 32_000])
        XCTAssertEqual(result?.transcript.utterances.first?.sourceName, "RODE")
    }

    func testLongRecordingOverlapIsNotDuplicatedAndAllRequestsStayBounded() async throws {
        var original = RecordingTranscript()
        original.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000,
            text: String(repeating: "Hello there. The next sentence is already correct. ", count: 150)))
        original.finish(fallback: "", endSample: 16_000)
        let editor = EchoTextEditor()
        let processor = SessionPostProcessor(detector: FakeLanguageDetector(), editor: editor)
        let result = try await processor.process(url: URL(fileURLWithPath: "/unused.wav"), transcript: original, modelID: nil)
        let requests = await editor.inputs
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.count <= TranscriptEditPolicy.maximumCharacters })
        XCTAssertEqual(result?.transcript.text, original.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(result?.transcript.utterances.map(\.id), [1])
    }
}

private actor EchoTextEditor: TranscriptEditing {
    var inputs: [String] = []
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        inputs.append(request.text)
        return .init(text: request.text, modelID: "echo")
    }
    func unload() async {}
}

private actor WholeSentenceEditor: TranscriptEditing {
    var inputs: [String] = []
    private let output: String
    init(_ output: String) { self.output = output }
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        inputs.append(request.text)
        return .init(text: output, modelID: "whole-sentence")
    }
    func unload() async {}
}

private actor ChangingNumbersEditor: TranscriptEditing {
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        .init(text: request.text.contains("18:30") ? "Встреча в 19:30." : "До завтра.", modelID: "fake-provider")
    }
    func unload() async {}
}

actor RejectingTextEditor: TranscriptEditing {
    private var rejecting = true
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        if rejecting { throw TranscriptEditError.changedNumbers }
        return .init(text: request.text.capitalized + ".", modelID: "fake-provider")
    }
    func unload() async { rejecting = false }
}

@MainActor final class FakeLanguageDetector: SessionLanguageDetecting {
    var language: String? = "fi"
    var closeCount = 0
    var prepareCount = 0
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws { prepareCount += 1 }
    func detect(url: URL) async throws -> String? { language }
    func close() async { closeCount += 1 }
}

private actor FakeTextEditor: TranscriptEditing {
    var requests: [TranscriptEditRequest] = []
    private let failAfter: Int?
    init(failAfter: Int? = nil) { self.failAfter = failAfter }
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        if requests.count == failAfter { throw CocoaError(.fileReadCorruptFile) }
        requests.append(request)
        return .init(text: request.text.capitalized + ".", modelID: "fake-provider")
    }
    func unload() async {}
}
