import XCTest
@testable import Murmur
@testable import MurmurKit

@MainActor final class OnboardingOwnershipTests: XCTestCase {
    private let keys = [ModelLoadingPolicy.key, SpeechLanguage.defaultsKey, TranslationSetting.key,
                        MicrophoneSetting.defaultsKey, "speechPostProcessingEnabled", DictationEnabled.key,
                        RightCommandTrigger.key]
    private var saved: [String: Any?] = [:]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(ModelLoadingPolicy.atLaunch.rawValue, forKey: ModelLoadingPolicy.key)
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        UserDefaults.standard.set(false, forKey: "speechPostProcessingEnabled")
        UserDefaults.standard.set(true, forKey: DictationEnabled.key)
        UserDefaults.standard.set(true, forKey: RightCommandTrigger.key)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key], let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testTourWaitsForBackgroundPreparationInsteadOfFailingWithBusy() async {
        let fake = FakeDictationSession()
        fake.rejectConcurrentPreparation = true
        var release: CheckedContinuation<Void, Never>?
        fake.prepareGate = {
            if fake.prepareCount == 1 { await withCheckedContinuation { release = $0 } }
        }
        let controller = DictationController(session: fake)
        controller.prepareCurrentMode()
        await until { release != nil }
        let model = OnboardingModel(session: fake, controller: controller)
        model.startDownload()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(model.downloadError, "the tour must not prepare a session still owned by the main app")
        release?.resume()
        await until { model.modelsReady || model.downloadError != nil }
        XCTAssertNil(model.downloadError)
        XCTAssertTrue(model.modelsReady)
    }

    func testTheSelectedMicrophoneIsPassedToTheTrialSession() async {
        UserDefaults.standard.set("qa-selected-input", forKey: MicrophoneSetting.defaultsKey)
        let fake = FakeDictationSession()
        let model = OnboardingModel(session: fake)
        model.flow.step = .fast
        model.modelsReady = true
        model.tryStart()
        await until { fake.startCount == 1 }
        XCTAssertEqual(fake.startedMicrophoneUID, "qa-selected-input")
        model.tryEnd(discard: true)
        await until { !model.tryWorking }
    }

    func testRightCommandOutsideTheTourReturnsLiveTextToTheMainHUD() async {
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        let model = OnboardingModel(session: fake, controller: controller)
        var focused = true
        model.isTourFocused = { focused }
        model.flow.step = .caret
        model.modelsReady = true
        let window = makeFocusedPracticeField(model, text: "", selection: NSRange(location: 0, length: 0))
        defer { window.close() }
        model.acquireTourSession()
        controller.handle(.rightCommandTap)
        await until { fake.startCount == 1 }
        await until { model.tryMicrophoneLive }
        XCTAssertTrue(model.tryMicrophoneLive)
        focused = false
        model.tourLostFocus()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 2)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertFalse(controller.onboardingOwnsSession)
        XCTAssertTrue(controller.hud.panelIsVisible)
        XCTAssertFalse(controller.companion.isVisible, "ordinary dictation has no mascot adviser")
        fake.onEvent?(.snapshot(.init(revision: 1, confirmed: [], provisional: "обычная диктовка")))
        XCTAssertEqual(controller.hud.model.partial, "обычная диктовка")
        XCTAssertEqual(model.tryPartial, "", "a background tour must not steal the main transcript")
        controller.cancelRecording()
        await controller.recordingTask?.value
    }

    func testAUnavailableMicrophoneFallsBackToSystemDefault() {
        UserDefaults.standard.set("disconnected-input", forKey: MicrophoneSetting.defaultsKey)
        let model = OnboardingModel(session: FakeDictationSession())
        model.availableMicrophones = { [] }
        model.refreshMicrophones()
        XCTAssertNil(MicrophoneSetting.currentUID)
        XCTAssertEqual(model.microphoneUID, MicrophoneSetting.systemDefaultUID)
        XCTAssertNotNil(model.disconnectedMicrophone, "the tour says the chosen input went away")
    }

    func testRightCommandHybridShowsTheDraftBeforeReplacingItWithAccurateText() async {
        let previousMode = UserDefaults.standard.object(forKey: ModelSetting.key)
        defer { UserDefaults.standard.set(previousMode, forKey: ModelSetting.key) }
        UserDefaults.standard.set(DictationMode.hybrid.rawValue, forKey: ModelSetting.key)
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startedMode, .hybrid)
        fake.onEvent?(.snapshot(.init(revision: 1, confirmed: [], provisional: "быстрый чернавик")))
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(controller.hud.model.partial, "быстрый чернавик")
        XCTAssertEqual(fake.stopCount, 0, "Live text must not wait for Return or the accurate pass")
        XCTAssertFalse(controller.companion.isVisible)
        fake.onEvent?(.snapshot(.init(revision: 2, confirmed: [
            .init(id: 0, startSample: 0, endSample: 16_000, text: "Быстрый черновик.", state: .confirmed)
        ], provisional: "")))
        XCTAssertEqual(controller.hud.model.confirmed, "Быстрый черновик.")
        XCTAssertEqual(controller.hud.model.partial, "")
        controller.cancelRecording()
        await controller.recordingTask?.value
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "The session did not reach its checkpoint")
    }
}
