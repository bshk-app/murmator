import AppKit
import XCTest
@testable import Murmur
@testable import MurmurKit

@MainActor final class OnboardingDemoTests: XCTestCase {
    private let keys = [SpeechLanguage.defaultsKey, TranslationSetting.key,
                        "speechPostProcessingEnabled", "speechPostProcessingModel"]
    private var saved: [String: Any?] = [:]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        UserDefaults.standard.set(true, forKey: "speechPostProcessingEnabled")
        UserDefaults.standard.set("automatic", forKey: "speechPostProcessingModel")
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key], let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testTheTranslationStepUsesItsPairAndTheCorrectorSetting() async {
        let fake = FakeDictationSession()
        fake.transcript.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000,
                                           text: "Привет.", translation: "Hello."))
        let model = OnboardingModel(session: fake)
        model.flow.step = .translation
        model.modelsReady = true
        model.practiceTranslationTarget = "en"
        model.tryStart()
        await until { model.tryMicrophoneLive }
        XCTAssertFalse(model.canContinue, "leaving must not transfer an active trial to the live app")
        XCTAssertEqual(fake.configuration?.profile.mode, .hybrid)
        XCTAssertEqual(fake.configuration?.profile.language, "ru")
        XCTAssertEqual(fake.configuration?.target, "en")
        XCTAssertEqual(fake.configuration?.postProcessing, true)
        XCTAssertEqual(fake.configuration?.localProvidersOnly, true)
        XCTAssertEqual(fake.configuration?.postProcessingModelID, "automatic")
        model.tryEnd()
        await until { !model.tryWorking }
        XCTAssertEqual(model.tryPhase, .done)
        XCTAssertEqual(model.tryTranslation, "Hello.")
        XCTAssertNil(model.tryError)
        XCTAssertTrue(model.canContinue)
        XCTAssertEqual(UserDefaults.standard.string(forKey: TranslationSetting.key), TranslationSetting.off,
                       "the example must not turn translation on for everyday dictation")
    }

    func testEachModeLessonRecordsInItsOwnModeWithoutTranslation() async {
        for (step, mode) in [(OnboardingFlow.Step.fast, DictationMode.fast), (.hybrid, .hybrid), (.accurate, .accurate)] {
            let fake = FakeDictationSession()
            let model = OnboardingModel(session: fake)
            model.flow.step = step
            model.modelsReady = true
            model.practiceTranslationTarget = "en"
            model.tryStart()
            await until { fake.startCount == 1 }
            XCTAssertEqual(fake.startedMode, mode, "\(step)")
            XCTAssertNil(fake.configuration?.target, "only the Translation step translates")
            model.tryEnd(discard: true)
            await until { !model.tryWorking }
        }
    }

    func testRightCommandInsertsAtAUnicodeSelectionOfTheFocusedPracticeField() async {
        let fake = FakeDictationSession()
        fake.transcript.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000, text: "Привет."))
        let model = OnboardingModel(session: fake)
        model.flow.step = .caret
        model.modelsReady = true
        let window = makeFocusedPracticeField(model, text: "до 😀 после", selection: NSRange(location: 3, length: 2))
        defer { window.close() }
        model.handleDemoGesture(.rightCommandTap)
        await until { model.tryMicrophoneLive }
        XCTAssertNil(fake.configuration?.target)
        model.handleDemoGesture(.confirm)
        await until { !model.tryWorking }
        XCTAssertEqual(model.demoText, "до Привет. после")
        XCTAssertEqual(model.demoSelection.location, 10)
        XCTAssertTrue(model.flow.didTry)
    }

    func testRightCommandWithoutAnInsertionPointAsksForOneAndRecordsNothing() async {
        let fake = FakeDictationSession()
        let model = OnboardingModel(session: fake)
        model.flow.step = .caret
        model.modelsReady = true
        model.handleDemoGesture(.rightCommandTap)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertTrue(model.caretNeedsFocus)
    }

    func testEscapeCancelsWithoutInsertingOrLosingTheBorrowedEventHandler() async {
        let fake = FakeDictationSession()
        var restoredCalls = 0
        fake.onEvent = { _ in restoredCalls += 1 }
        let model = OnboardingModel(session: fake)
        model.flow.step = .caret
        model.modelsReady = true
        let window = makeFocusedPracticeField(model, text: "keep me", selection: NSRange(location: 7, length: 0))
        defer { window.close() }
        model.handleDemoGesture(.rightCommandTap)
        await until { model.tryMicrophoneLive }
        model.handleDemoGesture(.cancel)
        await until { !model.tryWorking }
        XCTAssertEqual(model.demoText, "keep me")
        XCTAssertEqual(fake.stopCount, 0)
        XCTAssertTrue(model.tryCancelled)
        fake.onEvent?(.state(.ready))
        XCTAssertEqual(restoredCalls, 1)
    }

    func testReleasingBeforeTheMicrophoneOpensRecordsNothing() async {
        let fake = FakeDictationSession()
        var release: CheckedContinuation<Void, Never>?
        fake.startGate = { await withCheckedContinuation { release = $0 } }
        let model = OnboardingModel(session: fake)
        model.flow.step = .hybrid
        model.modelsReady = true
        model.tryStart()
        await until { release != nil }
        model.tryEnd()
        release?.resume()
        await until { !model.tryWorking }
        XCTAssertEqual(fake.stopCount, 0)
        XCTAssertNotEqual(fake.state, .recording, "a start that lands after the release is cancelled too")
        XCTAssertTrue(model.tryReleasedEarly)
        XCTAssertEqual(model.tryPhase, .idle)
    }

    func testCorrectorCanBeTurnedOffForTheNextExample() async {
        let fake = FakeDictationSession()
        let model = OnboardingModel(session: fake)
        model.flow.step = .corrector
        model.modelsReady = true
        model.setCorrector(false)
        model.tryStart()
        await until { fake.startCount == 1 }
        XCTAssertEqual(fake.configuration?.postProcessing, false)
        XCTAssertNil(fake.configuration?.target)
        model.tryEnd(discard: true)
        await until { !model.tryWorking }
    }

    func testATakeThatFinishesAfterLeavingDoesNotWriteIntoTheNextStep() async {
        let fake = FakeDictationSession()
        fake.transcript.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000, text: "Привет."))
        let model = OnboardingModel(session: fake)
        model.flow.step = .hybrid
        model.modelsReady = true
        model.tryStart()
        await until { model.tryMicrophoneLive }
        model.tryEnd()
        model.back()
        await until { !model.tryWorking }
        XCTAssertEqual(fake.stopCount, 1, "the released take still finishes on the session")
        XCTAssertEqual(model.step, .fast)
        XCTAssertEqual(model.tryConfirmed, "")
        XCTAssertEqual(model.tryPhase, .idle)
    }

    func testLeavingAnExampleStepStopsItsTake() async {
        let fake = FakeDictationSession()
        let model = OnboardingModel(session: fake)
        model.flow.step = .fast
        model.modelsReady = true
        model.tryStart()
        await until { model.tryMicrophoneLive }
        model.back()
        await until { !model.tryWorking }
        XCTAssertFalse(model.tryListening)
        XCTAssertEqual(fake.stopCount, 0, "leaving throws the take away instead of typing it")
        XCTAssertEqual(model.step, .models)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "The demo did not complete its asynchronous operation")
    }
}

/// A focused text view standing in for the tour's practice field.
@MainActor
func makeFocusedPracticeField(_ model: OnboardingModel, text: String, selection: NSRange) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.string = text
    window.contentView = view
    window.makeFirstResponder(view)
    view.setSelectedRange(selection)
    model.demoTextView = view
    model.demoText = text
    model.demoSelection = selection
    return window
}
