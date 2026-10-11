import XCTest
@testable import Murmur
@testable import MurmurKit

/// The popover's Start/Stop: without it a speaker with no shortcut to hand
/// (a clicker, a borrowed laptop) could not run Murmur at all.
@MainActor
final class MenuStartStopTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [AppMode.defaultsKey, TriggerMode.defaultsKey, ModelSetting.key,
                        SpeechLanguage.defaultsKey, TranslationSetting.key]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        // Hold is the case where a click differs from the hotkey: there is no key to release.
        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
        UserDefaults.standard.set("en", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key], let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func controller(mode: AppMode) -> (DictationController, FakeDictationSession) {
        UserDefaults.standard.set(mode.rawValue, forKey: AppMode.defaultsKey)
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        return (controller, fake)
    }

    func testTheMenuStartsAndStopsCaptions() async {
        let (controller, fake) = controller(mode: .captions)

        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .recording)

        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertNotEqual(controller.state, .recording)
    }

    /// Latched as hold, the HUD would show no Stop button and only a key
    /// release - of a key nobody pressed - could end the dictation.
    func testAMenuStartEndsOnATapEvenInHoldMode() async {
        let (controller, _) = controller(mode: .dictation)

        controller.toggleFromMenu()
        await controller.recordingTask?.value

        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.latchedToggle)
    }

    func testModelPreparationDoesNotClaimMicrophoneIsListening() async {
        let (controller, fake) = controller(mode: .dictation)
        let gate = ModelLoadGate()
        fake.prepareGate = { await gate.wait() }
        controller.toggleFromMenu()
        await until { gate.waiting }
        XCTAssertEqual(controller.state, .loadingModels)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertEqual(controller.keyCapture, .off)
        gate.open()
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        controller.cancelRecording()
        await controller.recordingTask?.value
    }

    func testLatestModelChoiceWinsDuringPreparation() async {
        let (controller, fake) = controller(mode: .dictation)
        let gate = ModelLoadGate()
        fake.prepareGate = { if fake.prepareCount == 1 { await gate.wait() } }
        UserDefaults.standard.set(DictationMode.fast.rawValue, forKey: ModelSetting.key)
        controller.prepareCurrentMode()
        await until { gate.waiting }
        UserDefaults.standard.set(DictationMode.accurate.rawValue, forKey: ModelSetting.key)
        controller.prepareCurrentMode()
        gate.open()
        await until { controller.state == .idle }
        XCTAssertEqual(fake.configuration?.profile.mode, .accurate)
        XCTAssertEqual(fake.prepareCount, 2)
    }

    func testMicrophoneOpeningDoesNotClaimListening() async {
        let (controller, fake) = controller(mode: .dictation)
        let gate = ModelLoadGate()
        fake.startGate = { await gate.wait() }
        controller.toggleFromMenu()
        await until { gate.waiting }
        XCTAssertEqual(controller.state, .startingRecording)
        XCTAssertFalse(controller.canChangeModels)
        XCTAssertNotEqual(controller.shortStatus, "Listening")
        controller.endRecording()
        gate.open()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertNotEqual(controller.state, .recording)
    }

    func testCancelLoadingWaitsForBothPreparationAndMemoryRelease() async {
        let (controller, fake) = controller(mode: .dictation)
        let loading = ModelLoadGate(), unloading = ModelLoadGate()
        fake.prepareGate = { await loading.wait() }
        fake.unloadGate = { await unloading.wait() }
        controller.prepareCurrentMode()
        await until { loading.waiting }
        controller.releaseModels()
        await until { unloading.waiting }
        XCTAssertEqual(controller.state, .unloadingModels)
        XCTAssertNil(controller.loadedModelName)
        controller.beginRecording(submit: false)
        XCTAssertEqual(fake.startCount, 0)
        unloading.open()
        await Task.yield()
        XCTAssertEqual(controller.state, .unloadingModels)
        loading.open()
        await until { controller.state == .modelsUnloaded }
        XCTAssertFalse(fake.isPrepared)
        XCTAssertNil(fake.configuration)
        fake.prepareGate = nil; fake.unloadGate = nil
        controller.prepareCurrentMode()
        await until { controller.state == .idle }
        XCTAssertTrue(fake.isPrepared)
        XCTAssertNotNil(controller.loadedModelName)
    }

    func testMemoryReleaseDoesNotInterruptALiveRecording() async {
        let (controller, fake) = controller(mode: .dictation)
        controller.toggleFromMenu()
        await controller.recordingTask?.value
        controller.releaseModels()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(fake.unloadCount, 0)
        controller.cancelRecording()
        await controller.recordingTask?.value
    }

    func testCancelStartDuringModelPreparationNeverOpensMicrophone() async {
        let (controller, fake) = controller(mode: .dictation)
        let gate = ModelLoadGate()
        fake.prepareGate = { await gate.wait() }
        controller.toggleFromMenu()
        await until { gate.waiting }
        controller.toggleFromMenu()
        XCTAssertEqual(controller.state, .unloadingModels)
        gate.open()
        await until { controller.state == .modelsUnloaded }
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertNil(controller.dictationSource)
        XCTAssertNil(controller.dictationMode)
    }

    func testTranslationPreparationEventsDoNotLeaveMenuLoading() {
        let (controller, _) = controller(mode: .dictation)
        controller.receive(.state(.preparing))
        controller.receive(.preparation(.init(stage: .translation, fraction: 0.5)))
        XCTAssertEqual(controller.state, .loadingModels)
        XCTAssertEqual(controller.modelPreparation?.fraction, 0.5)
        controller.receive(.state(.ready))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.modelPreparation)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Async model operation did not reach its checkpoint")
    }
}

@MainActor private final class ModelLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting = false
    func wait() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        waiting = false
    }
    func open() { continuation?.resume(); continuation = nil }
}
