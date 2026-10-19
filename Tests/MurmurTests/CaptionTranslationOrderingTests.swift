import XCTest
@testable import Murmur
@testable import MurmurKit

@MainActor
final class CaptionTranslationOrderingTests: XCTestCase {
    func testTranslationPreparationShowsDistinctDownloadFailures() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key, ModelSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        UserDefaults.standard.set(DictationMode.hybrid.rawValue, forKey: ModelSetting.key)
        let failures: [(Error, String)] = [
            (TranslationDownloader.Err.httpStatus(503, file: "model.bin"), "HTTP 503"),
            (TranslationDownloader.Err.digestMismatch(file: "model.bin", expected: "a", actual: "b"), "verification"),
            (TranslationDownloader.Err.insufficientSpace(needed: 200, available: 100), "disk space"),
            (URLError(.networkConnectionLost), "network connection was lost"),
        ]
        for (error, expected) in failures {
            let session = FakeDictationSession()
            session.preparationError = error
            let controller = DictationController(session: session)
            controller.prepareTranslation()
            for _ in 0..<500 {
                if case .error = controller.state { break }
                await Task.yield()
            }
            guard case .error(let message) = controller.state else {
                XCTFail("Translation failure disappeared: \(controller.state)")
                continue
            }
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertNil(controller.translationDownload)
            XCTAssertTrue(controller.translationPreparationError?.contains(expected) == true)
            XCTAssertTrue(controller.canRetryTranslationPreparation)
            controller.receive(.preparation(.init(stage: .translation, fraction: 0.9)))
            XCTAssertNil(controller.translationDownload, "Late progress hid the download failure")
        }
    }

    func testTranslationRetryClearsFailureAndPreparesOnlyOnce() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        session.preparationError = TranslationDownloader.Err.httpStatus(503, file: "model.bin")
        let controller = DictationController(session: session)
        controller.prepareTranslation()
        await translationSettles(controller)
        XCTAssertTrue(controller.canRetryTranslationPreparation)
        session.preparationError = nil
        var release: (() -> Void)?
        session.prepareGate = {
            await withCheckedContinuation { continuation in release = { continuation.resume() } }
        }
        controller.retryTranslationPreparation()
        controller.retryTranslationPreparation()
        for _ in 0..<500 {
            if release != nil { break }
            await Task.yield()
        }
        XCTAssertNil(controller.translationPreparationError)
        XCTAssertTrue(controller.isPreparingTranslation)
        XCTAssertFalse(controller.canRetryTranslationPreparation)
        XCTAssertEqual(session.prepareCount, 2)
        release?()
        await translationSettles(controller)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.translationDownload)
        XCTAssertNil(controller.translationPreparationError)
        XCTAssertFalse(controller.canRetryTranslationPreparation)
    }

    func testTurningTranslationOffClearsItsFailure() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        session.preparationError = URLError(.notConnectedToInternet)
        let controller = DictationController(session: session)
        controller.prepareTranslation()
        await translationSettles(controller)
        XCTAssertNotNil(controller.translationPreparationError)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        controller.prepareTranslation()
        XCTAssertNil(controller.translationPreparationError)
        XCTAssertFalse(controller.canRetryTranslationPreparation)
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartingDictationPreservesTheTranslationWarning() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key, AppMode.defaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
        let session = FakeDictationSession()
        session.preparationError = TranslationDownloader.Err.httpStatus(503, file: "model.bin")
        let controller = DictationController(session: session)
        controller.prepareTranslation()
        await translationSettles(controller)
        session.preparationError = nil
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.sessionWarning?.contains("HTTP 503") == true)
        XCTAssertFalse(controller.canRetryTranslationPreparation)
        controller.endRecording()
        await controller.recordingTask?.value
        XCTAssertNil(controller.translationPreparationError)
        XCTAssertNil(controller.sessionWarning)
    }

    func testCancelledTranslationPreparationCannotClearTheNextPreparation() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        var releases: [() -> Void] = []
        session.prepareGate = {
            await withCheckedContinuation { continuation in releases.append { continuation.resume() } }
        }
        let controller = DictationController(session: session)
        controller.prepareTranslation()
        for _ in 0..<500 {
            if releases.count == 1 { break }
            await Task.yield()
        }
        guard releases.count == 1 else { return XCTFail("First preparation did not start") }
        UserDefaults.standard.set("de", forKey: TranslationSetting.key)
        controller.prepareTranslation()
        releases[0]()
        for _ in 0..<500 {
            if releases.count == 2 { break }
            await Task.yield()
        }
        guard releases.count == 2 else { return XCTFail("Second preparation did not start") }
        XCTAssertTrue(controller.isPreparingTranslation)
        XCTAssertNil(controller.translationPreparationError)
        releases[1]()
        await translationSettles(controller)
        XCTAssertEqual(session.configuration?.target, "de")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.translationPreparationError)
    }

    func testTurningTranslationOffWaitsForCancelledPreparation() async {
        let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        session.ready = false
        var release: (() -> Void)?
        session.prepareGate = {
            await withCheckedContinuation { continuation in release = { continuation.resume() } }
        }
        let controller = DictationController(session: session)
        controller.prepareTranslation()
        for _ in 0..<500 {
            if release != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(release)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        controller.prepareTranslation()
        XCTAssertTrue(controller.isPreparingTranslation)
        release?()
        await translationSettles(controller)
        XCTAssertFalse(controller.isPreparingTranslation)
        XCTAssertEqual(controller.state, .modelsUnloaded)
        XCTAssertNil(controller.translationDownload)
        XCTAssertNil(controller.translationPreparationError)
    }

    private func translationSettles(_ controller: DictationController, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if !controller.isPreparingTranslation { return }
            await Task.yield()
        }
        XCTFail("Translation preparation did not settle", file: file, line: line)
    }

    func testTargetChangesAreDelegatedToTheSharedSession() async {
        let saved = UserDefaults.standard.object(forKey: TranslationSetting.key)
        defer { UserDefaults.standard.set(saved, forKey: TranslationSetting.key) }
        let session = FakeDictationSession()
        let controller = DictationController(session: session)
        controller.captionSource = "ru"
        for target in ["en", "de", TranslationSetting.off] {
            UserDefaults.standard.set(target, forKey: TranslationSetting.key)
            controller.updateCaptionTarget()
            await controller.captionTranslateTask?.value
        }
        XCTAssertEqual(session.targets.count, 3)
        XCTAssertEqual(session.targets[0], "en")
        XCTAssertEqual(session.targets[1], "de")
        XCTAssertNil(session.targets[2])
    }

    func testIncompleteTranslationFallsBackToTheWholeOriginal() {
        var transcript = RecordingTranscript()
        transcript.appendSettled(.init(id: 1, startSample: 0, endSample: 100, text: "First"))
        transcript.appendSettled(.init(id: 2, startSample: 100, endSample: 200, text: "Second"))
        transcript.applyTranslations([.init(id: 1, source: "First", text: "Первый", isFinal: true)])
        XCTAssertEqual(DictationController.completeTranslation(in: transcript), "")
        transcript.applyTranslations([.init(id: 2, source: "Second", text: "Второй", isFinal: true)])
        XCTAssertEqual(DictationController.completeTranslation(in: transcript), "Первый Второй")
    }

    func testAWordMergedAcrossAudioSpansDoesNotMakeTranslationIncomplete() {
        var transcript = RecordingTranscript()
        transcript.appendSettled(.init(id: 8, startSample: 0, endSample: 16_000, text: "За"))
        transcript.appendSettled(.init(id: 9, startSample: 16_000, endSample: 32_000, text: "чик"))
        transcript.finish(fallback: "", endSample: 32_000)
        transcript.applyFinalTextEdit("Зайчик.")
        transcript.applyTranslations([.init(id: 8, source: "Зайчик.", text: "Rabbit.", isFinal: true)])
        XCTAssertEqual(DictationController.completeTranslation(in: transcript), "Rabbit.")
        XCTAssertEqual(transcript.utterances.map(\.id), [8, 9])
    }

    func testCorrectionFailureLeavesTheRecordingStoppable() async {
        let keys = [AppMode.defaultsKey, SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(AppMode.captions.rawValue, forKey: AppMode.defaultsKey)
        UserDefaults.standard.set("en", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        let controller = DictationController(session: session)
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        controller.receive(.failure(.recognition("Correction failed")))
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(controller.sessionWarning, "Correction failed")
        controller.endRecording()
        await controller.recordingTask?.value
        XCTAssertEqual(session.stopCount, 1)
    }

    func testTranslationPreparationFailureStillFinishesTheSession() async {
        let keys = [AppMode.defaultsKey, SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set("en", forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        session.translationError = NSError(domain: "test", code: 1)
        let controller = DictationController(session: session)
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        controller.endRecording()
        await controller.recordingTask?.value
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(controller.state, .transcribed(""))
        XCTAssertNotNil(controller.sessionWarning)
    }

    func testAReleaseDuringAsyncStartStopsExactlyOnceAfterCaptureStarts() async {
        let keys = [AppMode.defaultsKey, SpeechLanguage.defaultsKey, TranslationSetting.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(AppMode.captions.rawValue, forKey: AppMode.defaultsKey)
        UserDefaults.standard.set("en", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        let session = FakeDictationSession()
        var release: (() -> Void)?
        session.startGate = {
            await withCheckedContinuation { continuation in release = { continuation.resume() } }
        }
        let controller = DictationController(session: session)
        controller.beginRecording(submit: false)
        // Release during microphone opening, not during model preparation.
        for _ in 0..<500 {
            if release != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(release)
        controller.endRecording()
        release?()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(session.startCount, 1)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(controller.state, .transcribed(""))
    }
}
