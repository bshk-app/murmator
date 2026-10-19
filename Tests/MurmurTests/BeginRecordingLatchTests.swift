import XCTest
@testable import Murmur
@testable import MurmurKit

/// What `beginRecording` latches, proved by running it with a substituted
/// session, and that a latched value beats a later change to the setting.
///
/// The assertions are deliberately written against what the *recogniser was
/// handed* as well as what was latched, because the bug being prevented is
/// the two disagreeing - not either one being any particular value.
@MainActor
final class BeginRecordingLatchTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [SpeechLanguage.defaultsKey, ModelSetting.key, AppMode.defaultsKey]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        // Dictation, not captions: pinned so the run does not depend on the
        // mode the developer last used.
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
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

    /// Returns the controller and its substituted session, already started.
    private func record(language: String, model: DictationMode)
        async -> (DictationController, FakeDictationSession) {
        UserDefaults.standard.set(language, forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(model.rawValue, forKey: ModelSetting.key)
        let controller = DictationController()
        let fake = FakeDictationSession()
        controller.session = fake
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1, "the session never started; the test asserts nothing")
        return (controller, fake)
    }

    /// The mutation this exists for: delete `dictationSource = language`.
    func testTheSourceHandedToTheRecogniserIsTheSourceLatched() async {
        let (controller, fake) = await record(language: "ru", model: .hybrid)

        XCTAssertEqual(fake.startedLanguage, "ru")
        XCTAssertEqual(controller.dictationSource, "ru")

        // The latch only means anything if it outlives a change to the
        // setting - otherwise reading the setting again would look identical.
        UserDefaults.standard.set("de", forKey: SpeechLanguage.defaultsKey)
        XCTAssertEqual(controller.translationSource, "ru")
        XCTAssertEqual(controller.dictationSource, fake.startedLanguage,
                       "the recogniser and the translation must agree on what was said")
    }

    /// The other mutation: latch `ModelSetting.current` instead of the
    /// downgraded `modelMode`. Japanese has no live draft, so Hybrid really
    /// runs as Accurate - the two values differ with nobody touching anything.
    func testTheModeHandedToTheRecogniserIsTheModeLatched() async {
        let (controller, fake) = await record(language: "ja", model: .hybrid)

        XCTAssertEqual(fake.startedMode, .accurate,
                       "ja is expected to have no live draft; test assumption is stale")
        XCTAssertEqual(controller.dictationMode, .accurate)
        XCTAssertEqual(controller.completedModelMode, .accurate)
        XCTAssertNotEqual(controller.completedModelMode, ModelSetting.current,
                          "the picker still says Hybrid; if these matched, the test could not "
                          + "tell the effective mode from the requested one")
        XCTAssertEqual(controller.dictationMode, fake.startedMode,
                       "analytics must name the lane that actually ran")
    }

    /// A language that keeps its live draft is not downgraded, so the same
    /// two values agree - proving the previous test failed for the right
    /// reason rather than because the latch is hardcoded.
    func testAnUndowngradedLanguageLatchesTheRequestedMode() async {
        let (controller, fake) = await record(language: "ru", model: .hybrid)
        XCTAssertEqual(fake.startedMode, .hybrid)
        XCTAssertEqual(controller.dictationMode, .hybrid)

        // Switching Model mid-utterance must not relabel the one that ran.
        UserDefaults.standard.set(DictationMode.accurate.rawValue, forKey: ModelSetting.key)
        XCTAssertEqual(controller.completedModelMode, .hybrid)
    }

    /// A session that never started must not leave a latch behind claiming it
    /// did, or the next stop would describe an utterance that never happened.
    func testAFailedStartLatchesNothing() async {
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        let controller = DictationController()
        let fake = FakeDictationSession()
        fake.startError = NSError(domain: "test", code: 1)
        controller.session = fake
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value

        XCTAssertNil(controller.dictationSource)
        XCTAssertNil(controller.dictationMode)
    }

    /// Not ready means the press is spent on loading and no utterance begins.
    func testAnUnreadySessionLatchesOnlyAfterTheMicrophoneStarts() async {
        UserDefaults.standard.set("ru", forKey: SpeechLanguage.defaultsKey)
        let controller = DictationController()
        let fake = FakeDictationSession()
        fake.ready = false
        var resume: CheckedContinuation<Void, Never>?
        fake.prepareGate = { await withCheckedContinuation { resume = $0 } }
        controller.session = fake
        controller.beginRecording(submit: false)
        for _ in 0..<1_000 {
            if resume != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(resume)
        XCTAssertEqual(fake.startCount, 0)
        XCTAssertNil(controller.dictationSource)
        XCTAssertNil(controller.dictationMode)
        resume?.resume()
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.dictationSource, fake.startedLanguage)
        XCTAssertEqual(controller.dictationMode, fake.startedMode)
    }

    /// Nothing ran, so the live settings are the only answer available.
    func testWithoutALatchTheCurrentSettingsAreUsed() {
        UserDefaults.standard.set("de", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(DictationMode.fast.rawValue, forKey: ModelSetting.key)
        let controller = DictationController()

        XCTAssertNil(controller.dictationSource)
        XCTAssertNil(controller.dictationMode)
        XCTAssertEqual(controller.translationSource, "de")
        XCTAssertEqual(controller.completedModelMode, .fast)
    }
}
