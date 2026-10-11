import XCTest
@testable import Murmur
@testable import MurmurKit

@MainActor
final class CaptionTranslationOrderingTests: XCTestCase {
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
