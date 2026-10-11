import XCTest
import MurmurCore
import MurmurSpeech
import MurmurTranslation
@testable import MurmurSession

@MainActor final class RecordingSessionTests: XCTestCase {
    private func configuration(target: String? = "en") throws -> RecordingSession.Configuration {
        .init(profile: try .resolve(language: "ru", mode: .hybrid), target: target)
    }
    private func snapshot(_ text: String, revision: UInt64 = 1, provisional: String = "") -> CaptionSnapshot {
        .init(revision: revision, confirmed: [.init(id: 1, startSample: 0, endSample: 16_000, text: text, state: .confirmed)], provisional: provisional)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }
    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 { if condition() { return }; await Task.yield() }
        XCTFail("Asynchronous operation did not reach expected checkpoint", file: file, line: line)
    }
    private func make(_ speech: FakeSpeech, _ translation: FakeTranslation) -> RecordingSession {
        .init(makeSpeech: { _ in speech }, translator: translation)
    }

    func testSourceFinishesBeforeTranslationAndFinalSnapshotWins() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: "selected-mic")
        speech.onSnapshot?(snapshot("draft"))
        speech.finalSnapshot = snapshot("corrected", revision: 2, provisional: "tail")
        speech.finalText = "corrected tail"
        let source = try await session.stopSource()
        XCTAssertEqual(source.text, "corrected tail")
        XCTAssertEqual(source.duration, 2)
        XCTAssertTrue(source.transcript.utterances.allSatisfy(\.settled))
        XCTAssertEqual(translation.finishTargets, [])
        XCTAssertEqual(session.state, .finishing)
        // Source is available for durable saving before a fallible quality pass.
        let savedSource = source.transcript
        let final = try await session.finishTranslation()
        XCTAssertEqual(savedSource.text, "corrected tail")
        XCTAssertEqual(final.translation, "en:corrected en:tail")
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(speech.microphone, "selected-mic")
    }

    func testFailedFinalRejectsPreviewAndAllowsFreshPreparation() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.onSnapshot?(.init(revision: 1, confirmed: [], provisional: "unfinished preview"))
        speech.failStop = true
        do { _ = try await session.stopSource(); XCTFail("Failed final became a deliverable result") }
        catch FakeFailure.recognition {}
        XCTAssertEqual(session.transcript.provisional, "")
        XCTAssertTrue(session.transcript.utterances.isEmpty)
        XCTAssertEqual(translation.finishTargets, [])
        XCTAssertEqual(speech.closeCount, 1)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isPrepared)
        speech.failStop = false
        try await session.prepare(configuration(target: nil))
        XCTAssertTrue(session.isPrepared)
        await session.unload()
    }

    func testCorrectedPhraseRejectsOldPreviewAndSegmentCallbacks() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        var displayed: [String] = []
        session.onEvent = { if case .translation(let text, _) = $0 { displayed.append(text) } }
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.onSnapshot?(snapshot("old"))
        await until { translation.updates.count == 1 }
        let old = translation.updates[0]
        old.segments([.init(id: 1, source: "old", text: "old translation", isFinal: true)])
        await settle()
        XCTAssertEqual(session.transcript.translatedText, "old translation")
        speech.onSnapshot?(snapshot("corrected", revision: 2))
        await until { translation.updates.count == 2 }
        XCTAssertEqual(session.transcript.translatedText, "")
        old.preview("stale preview")
        old.segments([.init(id: 1, source: "old", text: "stale quality", isFinal: true)])
        translation.updates[1].segments([.init(id: 1, source: "corrected", text: "new quality", isFinal: true)])
        await settle()
        XCTAssertFalse(displayed.contains("stale preview"))
        XCTAssertEqual(session.transcript.translatedText, "new quality")
        await session.unload()
    }

    func testOldSpeechCallbacksCannotModifyNextRecording() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        try await session.prepare(configuration(target: nil))
        try await session.start(microphoneUID: nil)
        let oldSnapshot = speech.onSnapshot, oldCapture = speech.onCapture
        speech.finalSnapshot = snapshot("first")
        _ = try await session.stop()
        try await session.start(microphoneUID: nil)
        oldSnapshot?(snapshot("stale", revision: 99))
        oldCapture?(160_000, 1)
        XCTAssertEqual(session.transcript.text, "")
        XCTAssertEqual(session.capturedSeconds, 0)
        speech.onSnapshot?(snapshot("second"))
        XCTAssertEqual(session.transcript.text, "second")
        await session.unload()
    }

    func testCancellationDrainsUncooperativePreparationBeforeUnloading() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        speech.prepareGate = gate
        var constructions = 0
        let session = RecordingSession(makeSpeech: { _ in constructions += 1; return speech }, translator: translation)
        let config = try configuration()
        let prepare = Task { try await session.prepare(config) }
        await until { gate.waiting }
        let cancel = Task { await session.cancel() }
        await settle()
        XCTAssertEqual(speech.closeCount, 0)
        XCTAssertEqual(translation.unloadCount, 0)
        do { try await session.prepare(config); XCTFail("new owner entered while old prepare runs") }
        catch RecordingSession.LifecycleError.busy { }
        XCTAssertEqual(constructions, 1)
        gate.open()
        await cancel.value
        do { try await prepare.value; XCTFail("cancelled preparation succeeded") }
        catch is CancellationError { }
        XCTAssertEqual(speech.closeCount, 1)
        XCTAssertEqual(translation.unloadCount, 1)
        XCTAssertEqual(session.state, .idle)
        speech.prepareGate = nil
        try await session.prepare(config)
        XCTAssertEqual(constructions, 2)
        await session.unload()
    }

    func testSecondStartWhileFirstStartSuspendsIsBusy() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        speech.startGate = gate
        let session = make(speech, translation)
        try await session.prepare(configuration(target: nil))
        let first = Task { try await session.start(microphoneUID: nil) }
        await until { gate.waiting }
        do { try await session.start(microphoneUID: nil); XCTFail("two captures started") }
        catch RecordingSession.LifecycleError.busy { }
        XCTAssertEqual(speech.startCount, 1)
        gate.open()
        try await first.value
        await session.unload()
    }

    func testModelReplacementReportsReleaseBeforeLoadingNextModel() async throws {
        let old = FakeSpeech(), next = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        var constructions = 0
        let session = RecordingSession(makeSpeech: { _ in
            constructions += 1
            return constructions == 1 ? old : next
        }, translator: translation)
        try await session.prepare(configuration(target: nil))
        old.closeGate = gate
        var stages: [String] = []
        session.onEvent = { event in
            if case .preparation(let progress) = event { stages.append(String(describing: progress.stage)) }
        }
        let config = RecordingSession.Configuration(profile: try .resolve(language: "en", mode: .fast))
        let replacement = Task { try await session.prepare(config) }
        await until { gate.waiting }
        XCTAssertEqual(stages.last, "unloading")
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(next.prepareCount, 0)
        XCTAssertFalse(session.isPrepared)
        gate.open()
        try await replacement.value
        XCTAssertEqual(stages.last, "speech")
        XCTAssertEqual(next.prepareCount, 1)
        XCTAssertTrue(session.isPrepared)
        await session.unload()
    }

    func testExplicitReleaseReportsBusyUntilModelMemoryIsFreed() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        let session = make(speech, translation)
        let config = try configuration(target: nil)
        try await session.prepare(config)
        speech.closeGate = gate
        var stage: String?
        session.onEvent = { event in
            if case .preparation(let value) = event { stage = String(describing: value.stage) }
        }
        let release = Task { await session.unload() }
        await until { gate.waiting }
        XCTAssertEqual(stage, "unloading")
        XCTAssertEqual(session.state, .preparing)
        XCTAssertFalse(session.isPrepared)
        do { try await session.prepare(config); XCTFail("Loaded a new model before memory release finished") }
        catch RecordingSession.LifecycleError.busy {}
        gate.open()
        await release.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.configuration)
        XCTAssertEqual(translation.unloadCount, 1)
    }

    func testTargetChangeRejectsOldLanguageAndCanChangeAfterSourceFinishes() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.onSnapshot?(snapshot("source"))
        await until { translation.updates.count == 1 }
        let old = translation.updates[0]
        old.segments([.init(id: 1, source: "source", text: "english", isFinal: true)])
        await settle()
        try await session.setTranslation(target: "fi")
        XCTAssertEqual(session.transcript.text, "source")
        XCTAssertEqual(session.transcript.translatedText, "")
        old.segments([.init(id: 1, source: "source", text: "late english", isFinal: true)])
        await settle()
        XCTAssertEqual(session.transcript.translatedText, "")
        speech.finalSnapshot = snapshot("source", revision: 2)
        _ = try await session.stopSource()
        try await session.setTranslation(target: "de")
        XCTAssertTrue(session.transcript.utterances.allSatisfy(\.settled))
        let result = try await session.finishTranslation()
        XCTAssertEqual(translation.finishTargets, ["de"])
        XCTAssertEqual(result.text, "source")
        XCTAssertEqual(result.translation, "de:source")
    }

    func testFinalTranslationFailurePreservesFinalizedOriginal() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        translation.failFinish = true
        let session = make(speech, translation)
        var failures = 0
        session.onEvent = { if case .failure(.translation) = $0 { failures += 1 } }
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.finalSnapshot = snapshot("original")
        let source = try await session.stopSource()
        do { _ = try await session.finishTranslation(); XCTFail("failed translation succeeded") }
        catch FakeFailure.translation { }
        XCTAssertEqual(source.text, "original")
        XCTAssertEqual(session.transcript.text, "original")
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(failures, 1)
    }

    func testSameProfileReusesPreparedSpeechAndTranslation() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        var constructions = 0
        let session = RecordingSession(makeSpeech: { _ in constructions += 1; return speech }, translator: translation)
        let config = try configuration()
        try await session.prepare(config)
        try await session.prepare(config)
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(speech.prepareCount, 1)
        XCTAssertEqual(translation.preparedTargets, ["en"])
        XCTAssertTrue(session.isPrepared)
        await session.unload()
        XCTAssertFalse(session.isPrepared)
    }

    func testSameLanguageDisablesTranslationAndFallbackSurvivesEmptySnapshot() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        try await session.prepare(configuration(target: "ru"))
        try await session.start(microphoneUID: nil)
        speech.finalText = "fallback"
        let result = try await session.stop()
        XCTAssertEqual(result.text, "fallback")
        XCTAssertEqual(result.translation, "")
        XCTAssertTrue(translation.preparedTargets.isEmpty)
        XCTAssertTrue(translation.finishTargets.isEmpty)
    }

    func testFatalCaptureErrorPublishesOnlyAfterAcceptedSourceIsFinalized() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        var sourceAtFailure: String?
        var stateAtFailure: RecordingSession.State?
        session.onEvent = { event in
            if case .failure(.capture) = event {
                sourceAtFailure = session.transcript.text
                stateAtFailure = session.state
            }
        }
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.finalSnapshot = snapshot("accepted audio")
        speech.onCaptureError?("overloaded")
        await until { sourceAtFailure != nil }
        XCTAssertEqual(sourceAtFailure, "accepted audio")
        XCTAssertEqual(stateAtFailure, .finishing)
        let source = try await session.stopSource()
        XCTAssertEqual(source.text, "accepted audio")
        XCTAssertTrue(source.transcript.utterances.allSatisfy(\.settled))
        _ = try await session.finishTranslation()
    }

    func testRecordingFileFailureDoesNotStopRecognition() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation()
        let session = make(speech, translation)
        var failures = 0
        session.onEvent = { if case .failure(.recording) = $0 { failures += 1 } }
        try await session.prepare(configuration(target: nil))
        try await session.start(microphoneUID: nil)
        speech.onRecordingError?("disk full")
        speech.onSnapshot?(snapshot("still transcribing"))
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.transcript.text, "still transcribing")
        await session.unload()
    }

    func testTargetCannotChangeWhileFinalTranslationIsInFlight() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        translation.finishGate = gate
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        speech.finalSnapshot = snapshot("original")
        _ = try await session.stopSource()
        let finish = Task { try await session.finishTranslation() }
        await until { gate.waiting }
        do { try await session.setTranslation(target: "fi"); XCTFail("target changed beneath final translation") }
        catch RecordingSession.LifecycleError.busy { }
        gate.open()
        let result = try await finish.value
        XCTAssertEqual(result.translation, "en:original")
        XCTAssertEqual(session.configuration?.target, "en")
    }

    func testStopCancelsAndDrainsTargetPreparationBeforeFinalizingSource() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        translation.prepareGate = gate
        let change = Task { try await session.setTranslation(target: "fi") }
        await until { gate.waiting }
        speech.finalSnapshot = snapshot("retained original")
        let stop = Task { try await session.stopSource() }
        await settle()
        XCTAssertEqual(session.state, .recording)
        gate.open()
        do { try await change.value; XCTFail("cancelled target preparation succeeded") }
        catch is CancellationError { }
        let source = try await stop.value
        XCTAssertEqual(source.text, "retained original")
        XCTAssertEqual(session.state, .finishing)
        XCTAssertNil(session.configuration?.target)
        _ = try await session.finishTranslation()
    }

    func testNewTargetWaitsForCancelledPreviousPreparation() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        let session = make(speech, translation)
        try await session.prepare(configuration())
        try await session.start(microphoneUID: nil)
        translation.prepareGate = gate
        let first = Task { try await session.setTranslation(target: "fi") }
        await until { gate.waiting }
        let replacement = Task { try await session.setTranslation(target: "de") }
        await settle()
        XCTAssertEqual(translation.preparedTargets, ["en", "fi"])
        translation.prepareGate = nil
        gate.open()
        do { try await first.value; XCTFail("superseded target became active") }
        catch is CancellationError { }
        try await replacement.value
        XCTAssertEqual(translation.preparedTargets, ["en", "fi", "de"])
        XCTAssertEqual(session.configuration?.target, "de")
        XCTAssertEqual(session.state, .recording)
        await session.unload()
    }

    func testStopWaitingForTargetCannotCrossUnloadGeneration() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        let session = make(speech, translation)
        let config = try configuration()
        try await session.prepare(config)
        try await session.start(microphoneUID: nil)
        translation.prepareGate = gate
        let change = Task { try await session.setTranslation(target: "fi") }
        await until { gate.waiting }
        let stop = Task { try await session.stopSource() }
        await settle()
        let unload = Task { await session.unload() }
        await settle()
        translation.prepareGate = nil
        gate.open()
        await unload.value
        _ = try? await change.value
        do { _ = try await stop.value; XCTFail("old stop crossed session generation") }
        catch is CancellationError { }
        try await session.prepare(config)
        try await session.start(microphoneUID: nil)
        XCTAssertEqual(session.state, .recording)
        await session.unload()
    }

    func testFailedPreparationKeepsCloseOwnedUntilCancellationDrainsIt() async throws {
        let speech = FakeSpeech(), translation = FakeTranslation(), gate = Gate()
        speech.failPrepare = true
        speech.closeGate = gate
        let session = make(speech, translation)
        let config = try configuration()
        let prepare = Task { try await session.prepare(config) }
        await until { gate.waiting }
        do { try await session.prepare(config); XCTFail("replacement entered before failed model was released") }
        catch RecordingSession.LifecycleError.busy { }
        let unload = Task { await session.unload() }
        await settle()
        XCTAssertEqual(translation.unloadCount, 0)
        speech.closeGate = nil
        gate.open()
        await unload.value
        do { try await prepare.value; XCTFail("failed preparation succeeded") }
        catch { }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(translation.unloadCount, 1)
        speech.failPrepare = false
        try await session.prepare(config)
        XCTAssertEqual(session.state, .ready)
        await session.unload()
    }
}

@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private enum FakeFailure: Error { case translation, preparation, recognition }

@MainActor private final class FakeSpeech: SessionSpeechDriving {
    var onSnapshot: ((CaptionSnapshot) -> Void)?
    var onCapture: ((Int, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    var capturedSeconds = 2.0
    var prepareCount = 0, startCount = 0, closeCount = 0
    var prepareGate: Gate?, startGate: Gate?
    var closeGate: Gate?
    var failPrepare = false
    var failStop = false
    var microphone: String?
    var finalText = ""
    var finalSnapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws {
        prepareCount += 1
        if let prepareGate { await prepareGate.wait() }
        if failPrepare { throw FakeFailure.preparation }
    }
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
        startCount += 1; microphone = microphoneUID
        if let startGate { await startGate.wait() }
    }
    func stop() async throws -> String {
        if failStop { throw FakeFailure.recognition }
        return finalText
    }
    func snapshot() async -> CaptionSnapshot { finalSnapshot }
    func close() async { closeCount += 1; if let closeGate { await closeGate.wait() } }
}

@MainActor private final class FakeTranslation: SessionTranslationDriving {
    struct Update {
        let preview: @Sendable (String) -> Void
        let segments: @Sendable ([UtteranceTranslation]) -> Void
    }
    var residentModelCount: Int { get async { 0 } }
    var preparedTargets: [String] = [], finishTargets: [String] = []
    var updates: [Update] = []
    var unloadCount = 0
    var failFinish = false
    var finishGate: Gate?
    var prepareGate: Gate?
    func prepare(from: String, to: String, priority: ProcessingQuality,
                 progress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws {
        preparedTargets.append(to)
        if let prepareGate { await prepareGate.wait() }
    }
    func warmUp(from: String, to: String) async throws { }
    func update(_ snapshot: CaptionSnapshot, from: String, to: String,
                onUpdate: @escaping @Sendable (String) -> Void,
                onFailure: @escaping @Sendable (String) -> Void,
                onSegments: @escaping @Sendable ([UtteranceTranslation]) -> Void) async {
        updates.append(.init(preview: onUpdate, segments: onSegments))
    }
    func finish(_ utterances: [RecordedUtterance], from: String, to: String,
                onSegment: @escaping @Sendable (UtteranceTranslation) async -> Void) async throws {
        finishTargets.append(to)
        if let finishGate { await finishGate.wait() }
        if failFinish { throw FakeFailure.translation }
        for utterance in utterances {
            await onSegment(.init(id: utterance.id, source: utterance.text, text: "\(to):\(utterance.text)", isFinal: true))
        }
    }
    func cancel() async { }
    func unload() async { unloadCount += 1 }
}
