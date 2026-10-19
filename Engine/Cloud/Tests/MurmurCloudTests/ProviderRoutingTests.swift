import Foundation
import XCTest
import MurmurCore
import MurmurSession
import MurmurSpeech
import AIProvidersCore
@testable import MurmurCloud

@MainActor private final class LocalLane: SessionSpeechDriving {
    var onSnapshot: ((CaptionSnapshot) -> Void)?
    var onCapture: ((Int, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    var capturedSeconds = 2.0
    var value = CaptionSnapshot(revision: 1, confirmed: [.init(id: 17, startSample: 0, endSample: 16000, text: "Draft phrase", state: .confirmed)], provisional: "live tail")
    var starts = 0
    var writer: PCMRecordingWriter?
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws {}
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
        starts += 1; writer = try PCMRecordingWriter(url: recordingURL!)
        try writer?.append([Float](repeating: 0.05, count: 32000)); onSnapshot?(value)
    }
    func snapshot() async -> CaptionSnapshot { value }
    func stop() async throws -> String { try writer?.finish(); return "Draft phrase" }
    func close() async { try? writer?.finish() }
    func updateTail() { value = .init(revision: 2, confirmed: value.confirmed, provisional: "new live tail"); onSnapshot?(value) }
}
private actor SuspendedASR: AISpeechProviding {
    private var continuation: CheckedContinuation<String, Never>?
    private let requested: XCTestExpectation
    init(requested: XCTestExpectation) { self.requested = requested }
    func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String {
        XCTAssertEqual(audio.prefix(4), Data("RIFF".utf8)); XCTAssertEqual(audio.count, 32044)
        return await withCheckedContinuation { continuation in self.continuation = continuation; requested.fulfill() }
    }
    func complete() { continuation?.resume(returning: "Accurate phrase"); continuation = nil }
}
@MainActor final class ProviderRoutingTests: XCTestCase {
    func testLocalDraftContinuesWhileCloudRefinesSameTimedPhrase() async throws {
        let requested = expectation(description: "cloud receives closed audio range")
        let refined = expectation(description: "accurate result replaces draft")
        let provider = SuspendedASR(requested: requested), base = LocalLane()
        let driver = LocalCloudRefiningDriver(base: base, provider: provider, request: .init(model: "quality", language: "ru"))
        driver.onSnapshot = { value in if value.confirmed.first?.text == "Accurate phrase" { refined.fulfill() } }
        try await driver.start(microphoneUID: nil, recordingURL: nil)
        await fulfillment(of: [requested], timeout: 2)
        base.updateTail()
        let draft = await driver.snapshot()
        XCTAssertEqual(draft.confirmed.first?.text, "Draft phrase"); XCTAssertEqual(draft.provisional, "new live tail")
        await provider.complete(); await fulfillment(of: [refined], timeout: 2)
        let final = await driver.snapshot()
        XCTAssertEqual(final.confirmed.first?.id, 17); XCTAssertEqual(final.confirmed.first?.startSample, 0); XCTAssertEqual(final.confirmed.first?.endSample, 16000)
        XCTAssertEqual(base.starts, 1); await driver.close()
    }
    func testCancelledCloudRefinementCannotPublishIntoAnotherTake() async throws {
        let requested = expectation(description: "request started")
        let forbidden = expectation(description: "no late output"); forbidden.isInverted = true
        let provider = SuspendedASR(requested: requested), base = LocalLane()
        let driver = LocalCloudRefiningDriver(base: base, provider: provider, request: .init(model: "quality", language: "ru"))
        driver.onSnapshot = { value in if value.confirmed.first?.text == "Accurate phrase" { forbidden.fulfill() } }
        try await driver.start(microphoneUID: nil, recordingURL: nil)
        await fulfillment(of: [requested], timeout: 2); await driver.close(); await provider.complete()
        await fulfillment(of: [forbidden], timeout: 0.1)
    }
    func testCloudCorrectorReceivesOneWholeFinalText() async throws {
        let provider = TextFixture()
        let editor = ProviderTranscriptEditor(provider: provider, model: "text-model")
        let text = "Первое предложение.\n\nВторое предложение."
        let result = try await editor.edit(.init(text: text, language: "ru"))
        let inputs = await provider.inputs
        let latencies = await provider.latencies
        XCTAssertEqual(inputs, [text]); XCTAssertEqual(result.text, text); XCTAssertEqual(result.modelID, "text-model")
        XCTAssertEqual(latencies, [.interactive])
        let traced = await provider.traced
        XCTAssertEqual(traced, [true], "the actual corrector supplies metadata-only request diagnostics")
    }
    func testCorrectorCapturesReasoningAndRoutingForItsTake() async throws {
        let provider = TextFixture()
        let options = AITextOptions(reasoningEffort: .low, routing: .init(only: ["groq"], allowFallbacks: false))
        let editor = ProviderTranscriptEditor(provider: provider, model: "text-model", options: options)
        _ = try await editor.edit(.init(text: "Original text.", language: "en"))
        let captured = await provider.options
        XCTAssertEqual(captured, [options])
    }
    func testRouteFingerprintIsStableAcrossReads() {
        let defaults = UserDefaults(suiteName: "providers-tests-\(UUID())")!
        let preferences = ProviderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.configurationID, preferences.configurationID)
        XCTAssertNil(preferences.selection(.textEditing)); XCTAssertNil(preferences.selection(.streamingTranscription))
        XCTAssertThrowsError(try preferences.select(.init(connectionID: UUID(), modelID: "wrong-kind"), for: .textEditing))
    }
    func testCloudCorrectionDeadlineCancelsTheRequest() async throws {
        let provider = StalledText()
        let editor = ProviderTranscriptEditor(provider: provider, model: "text", timeout: .milliseconds(20))
        do {
            _ = try await editor.edit(.init(text: "Original text.", language: "en"))
            XCTFail("A stalled optional corrector must release the finished transcript")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let cancelled = await provider.cancelled
        XCTAssertTrue(cancelled)
    }
    func testLastOpenPhraseIsRefinedAfterReleaseWithoutLostTail() async throws {
        let base = LocalLane(), provider = ImmediateASR()
        let driver = LocalCloudRefiningDriver(base: base, provider: provider, request: .init(model: "quality", language: "ru"))
        try await driver.start(microphoneUID: nil, recordingURL: nil)
        let text = try await driver.stop()
        let requests = await provider.byteCounts
        XCTAssertEqual(requests, [32044, 32044])
        XCTAssertEqual(text, "Accurate 1 Accurate 2")
        let snapshot = await driver.snapshot()
        XCTAssertEqual(snapshot.confirmed.map(\.id), [17, 18]); XCTAssertEqual(snapshot.confirmed.last?.endSample, 32000)
        XCTAssertTrue(snapshot.provisional.isEmpty); await driver.close()
    }
}
private actor ImmediateASR: AISpeechProviding {
    var byteCounts: [Int] = []
    func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String { byteCounts.append(audio.count); return "Accurate \(byteCounts.count)" }
}
private actor TextFixture: AITextProviding {
    var inputs: [String] = []
    var latencies: [AITextLatency] = []
    var traced: [Bool] = []
    var options: [AITextOptions] = []
    func models() async throws -> [AIModel] { [] }
    func generate(_ request: AITextRequest) async throws -> String {
        inputs.append(request.text); latencies.append(request.latency); traced.append(request.onProgress != nil)
        options.append(request.options)
        request.onProgress?(.init(stage: .credentialsReady, elapsedSeconds: 0))
        return request.text
    }
}
private actor StalledText: AITextProviding {
    var cancelled = false
    func models() async throws -> [AIModel] { [] }
    func generate(_ request: AITextRequest) async throws -> String {
        do { try await Task.sleep(for: .seconds(300)); return "Unexpected" }
        catch { cancelled = true; throw error }
    }
}
