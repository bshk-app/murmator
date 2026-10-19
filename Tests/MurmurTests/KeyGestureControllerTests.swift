import XCTest
@testable import Murmur
@testable import MurmurKit

/// Records what the controller asks the key tap to hold back.
private final class CaptureRecorder: KeyCaptureSink {
    private(set) var history: [KeyCapture] = []
    /// Stands in for a Return the tap held back while finishing.
    var heldBackReturn = false
    var current: KeyCapture? { history.last }
    func setCapture(_ capture: KeyCapture) {
        history.append(capture)
        if capture != .finishing { heldBackReturn = false }
    }
    func endCapture() -> Bool {
        history.append(.off)
        defer { heldBackReturn = false }
        return heldBackReturn
    }
}

/// "Tap right ⌘, talk, press Return": what each gesture does to a session, and
/// what the key tap is told to hold back at every step. The capture matters
/// as much as the gesture: left on after a dictation, it would swallow Return
/// in every app on the Mac.
@MainActor
final class KeyGestureControllerTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [AppMode.defaultsKey, TriggerMode.defaultsKey, RightCommandTrigger.key,
                        DictationEnabled.key, "speechPostProcessingEnabled"]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
        // Hold is the default and the case where a tap-started session differs
        // from a shortcut-started one.
        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
        UserDefaults.standard.removeObject(forKey: RightCommandTrigger.key)
        UserDefaults.standard.removeObject(forKey: DictationEnabled.key)
        UserDefaults.standard.set(false, forKey: "speechPostProcessingEnabled")
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

    private var returnsPressed = 0

    private func controller() -> (DictationController, FakeDictationSession, CaptureRecorder) {
        let controller = DictationController()
        let fake = FakeDictationSession()
        let recorder = CaptureRecorder()
        controller.session = fake
        controller.keyCaptureSink = recorder
        returnsPressed = 0
        controller.pressReturn = { [unowned self] in self.returnsPressed += 1 }
        return (controller, fake, recorder)
    }

    /// A tap-on dictation, finished with Return, its paste just posted.
    private func pasted(_ controller: DictationController, alreadySubmitting: Bool = false) async {
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value
        controller.holdReturnUntilPasteLands(alreadySubmitting: alreadySubmitting)
    }

    func testARightCommandTapStartsATapOnSessionThatReturnFinishes() async {
        let (controller, fake, recorder) = controller()

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.latchedToggle, "a tap leaves no key to release")
        XCTAssertTrue(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .recording)

        controller.handle(.confirm)
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertEqual(recorder.current, .finishing)

        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.finishCount, 1)
        XCTAssertEqual(controller.state, .transcribed(""))
        XCTAssertEqual(recorder.current, .off, "Return must be the apps' again once the text is in")
    }

    func testASecondTapStopsTooWithoutReturn() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Escape stops the microphone the ordinary way - the session's
    /// lifecycle must still close - and inserts nothing.
    func testEscapeThrowsTheDictationAway() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.cancel)
        XCTAssertEqual(recorder.current, .off,
                       "nothing is coming, so a Return now is the user's and must reach the app")
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.finishCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.submitRequested)
    }

    /// The race this exists for: Return, then Return again to send, before
    /// the final text is ready. The second one would otherwise reach the chat
    /// first and send it without the dictation in it.
    func testReturnWhileFinishingSendsAfterThePaste() async {
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value

        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        XCTAssertTrue(controller.submitRequested)
        XCTAssertGreaterThan(fake.skippedPostProcessingCount, 0)
        await controller.recordingTask?.value
    }

    func testRepeatedForceSubmitPastesTheSourceAndSendsExactlyOnce() async {
        let (controller, fake, _) = controller()
        fake.transcript.appendSettled(.init(id: 1, startSample: 0, endSample: 16_000, text: "Final ASR text"))
        controller.accessibilityTrusted = { true }
        var payloads: [String] = []
        var submitAfterRead = false
        var settled: (@Sendable (Bool) -> Void)?
        controller.pasteTranscript = { text, submit, callback in
            payloads.append(text); submitAfterRead = submit; settled = callback
            return .pasted
        }
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        controller.handle(.submitWhenDone)
        await controller.recordingTask?.value
        XCTAssertEqual(payloads, ["Final ASR text"])
        XCTAssertTrue(submitAfterRead)
        XCTAssertEqual(returnsPressed, 0)
        // Simulate TextInjector: its own submit goes once the text is read,
        // then it notifies the controller. A repeated notification cannot send.
        if submitAfterRead { controller.pressReturn() }
        settled?(true)
        controller.pasteDidSettle(landed: true, generation: controller.recordingGeneration)
        XCTAssertEqual(returnsPressed, 1)
        XCTAssertGreaterThan(fake.skippedPostProcessingCount, 0)
    }

    /// The first Return lands while the microphone is still opening, so the
    /// stop is deferred; the second must still mean "and send it".
    func testReturnTwiceDuringStartStillSends() async {
        let (controller, fake, _) = controller()
        var release: CheckedContinuation<Void, Never>?
        fake.startGate = { await withCheckedContinuation { release = $0 } }
        controller.handle(.rightCommandTap)
        guard let gate = await parked({ release }) else { return }

        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        XCTAssertTrue(controller.submitRequested)
        gate.resume()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertGreaterThan(fake.skippedPostProcessingCount, 1, "the skip is reapplied after the microphone actually opens")
    }

    /// Sleeps past `pasteSettleDelay`, so a timer that released a held Return
    /// on its own would already have fired when the test checks.
    private func settle() async {
        try? await Task.sleep(for: .seconds(TextInjector.pasteSettleDelay + 0.15))
    }

    /// The start gate's continuation once the session has parked on it; fails
    /// rather than hanging the run when start is never reached.
    private func parked(_ gate: () -> CheckedContinuation<Void, Never>?) async
        -> CheckedContinuation<Void, Never>? {
        for _ in 0..<1_000 {
            if let continuation = gate() { return continuation }
            await Task.yield()
        }
        XCTFail("the session never reached its start gate")
        return nil
    }

    /// What `TextInjector` reports for the current take's paste.
    private func pasteSettles(_ controller: DictationController, landed: Bool = true) {
        controller.pasteDidSettle(landed: landed, generation: controller.recordingGeneration)
    }

    /// After the paste is posted the chat may not have applied it yet; a
    /// Return let through then would send the field without the text. It
    /// stays held back until the paste has landed, then goes back to the app.
    func testReturnStaysCapturedWhileThePasteLands() async {
        let (controller, _, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value

        controller.holdReturnUntilPasteLands(alreadySubmitting: false)
        XCTAssertEqual(controller.keyCapture, .finishing)
        XCTAssertEqual(recorder.current, .finishing)
        await settle()
        XCTAssertTrue(controller.pasteSettling, "no timer lets it go: only the paste landing does")

        pasteSettles(controller)
        XCTAssertFalse(controller.pasteSettling)
        XCTAssertEqual(controller.keyCapture, .off)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Tapping straight into the next dictation: the old paste landing
    /// afterwards must not release Return from under the new recording.
    func testTheNextRecordingKeepsItsCaptureWhenTheOldPasteSettles() async {
        let (controller, _, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        await controller.recordingTask?.value
        controller.holdReturnUntilPasteLands(alreadySubmitting: false)
        let oldTake = controller.recordingGeneration

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)

        controller.pasteDidSettle(landed: true, generation: oldTake)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(recorder.current, .recording, "the old window closed over the new session")
    }

    /// Return pressed while the paste lands: sent once it has landed.
    func testAReturnHeldBackWhileThePasteLandsIsSentAfterIt() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true
        await settle()
        XCTAssertEqual(returnsPressed, 0, "not before the paste has landed, however slow the app")
        pasteSettles(controller)
        XCTAssertEqual(returnsPressed, 1)
    }

    /// No app took the text: a Return held back for it would send the field
    /// without it, so it is not sent - and Return is the app's again.
    func testAReturnHeldBackForAPasteThatNeverLandedIsNotSent() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true
        pasteSettles(controller, landed: false)
        XCTAssertEqual(returnsPressed, 0)
        XCTAssertFalse(controller.pasteSettling)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Dictate-and-send already ends with a Return; a second would send an
    /// empty message after it.
    func testNoSecondReturnWhenThePasteAlreadySends() async {
        let (controller, _, recorder) = controller()
        await pasted(controller, alreadySubmitting: true)
        recorder.heldBackReturn = true
        pasteSettles(controller)
        XCTAssertEqual(returnsPressed, 0)
    }

    /// Return to send A, then straight into dictation B: B's capture must not
    /// swallow A's send, and it waits for A's paste to land.
    func testTappingIntoTheNextDictationStillSendsThePreviousOne() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true
        let takeA = controller.recordingGeneration

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        await settle()
        XCTAssertEqual(returnsPressed, 0, "A's paste may not have landed yet")
        controller.pasteDidSettle(landed: true, generation: takeA)
        XCTAssertEqual(returnsPressed, 1)
        XCTAssertEqual(recorder.current, .recording)
    }

    /// The same, but A's text never landed: its Return is not sent.
    func testTheNextDictationDropsAReturnWhosePasteNeverLanded() async {
        let (controller, _, recorder) = controller()
        await pasted(controller)
        recorder.heldBackReturn = true
        let takeA = controller.recordingGeneration

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.pasteDidSettle(landed: false, generation: takeA)
        XCTAssertEqual(returnsPressed, 0)
        XCTAssertEqual(recorder.current, .recording)
    }

    /// A new dictation must not inherit the previous one's "and send it".
    func testASubmitRequestDoesNotOutliveItsSession() async {
        let (controller, _, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        controller.handle(.submitWhenDone)
        await controller.recordingTask?.value

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertFalse(controller.submitRequested)
    }

    /// Holding a chord already says when the dictation ends; Return and
    /// Escape stay with the app.
    func testAHoldSessionCapturesNothing() async {
        let (controller, _, recorder) = controller()
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        XCTAssertFalse(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .off)

        controller.handle(.confirm)
        controller.handle(.cancel)
        XCTAssertEqual(controller.state, .recording, "a Return that was never captured cannot stop it")

        // Nor does a tap take over a session someone is holding a chord for.
        controller.handle(.rightCommandTap)
        XCTAssertEqual(controller.state, .recording)
    }

    /// Every tap-on session finishes on Return, however it was started.
    func testToggleShortcutAndMenuSessionsFinishOnReturn() async {
        UserDefaults.standard.set(TriggerMode.toggle.rawValue, forKey: TriggerMode.defaultsKey)
        let (controller, _, recorder) = controller()
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)
        controller.handle(.confirm)
        await controller.recordingTask?.value

        UserDefaults.standard.set(TriggerMode.hold.rawValue, forKey: TriggerMode.defaultsKey)
        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .recording)
    }

    /// A talk runs for an hour while the speaker types notes.
    func testCaptionsCaptureNothing() async {
        UserDefaults.standard.set(AppMode.captions.rawValue, forKey: AppMode.defaultsKey)
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertFalse(controller.confirmsWithReturn)
        XCTAssertEqual(recorder.current, .off)
    }

    func testTheTapCanBeSwitchedOff() async {
        UserDefaults.standard.set(false, forKey: RightCommandTrigger.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }

    /// Same rule as the shortcut: the master switch blocks starting.
    func testTheMasterSwitchBlocksTheTap() async {
        UserDefaults.standard.set(false, forKey: DictationEnabled.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }

    /// A failed start must release Return, or a broken microphone would also
    /// break the Return key.
    func testAFailedStartReleasesTheCapture() async {
        let (controller, fake, recorder) = controller()
        fake.startError = NSError(domain: "test", code: 1)
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(recorder.current, .off)
    }

    /// Escape pressed while the microphone is still opening: the session
    /// starts, stops at once, and nothing is inserted.
    func testEscapeDuringStartStillDiscards() async {
        let (controller, fake, recorder) = controller()
        var release: CheckedContinuation<Void, Never>?
        fake.startGate = { await withCheckedContinuation { release = $0 } }
        controller.handle(.rightCommandTap)
        guard let gate = await parked({ release }) else { return }

        controller.handle(.cancel)
        gate.resume()
        await controller.recordingTask?.value
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.current, .off)
    }

    // MARK: holding right ⌘

    /// The microphone opens with the key still down, and letting go inserts.
    func testHoldingRightCommandTalksUntilItIsLetGo() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.heldPressStarted)

        controller.handle(.rightCommandReleased)
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertEqual(recorder.current, .finishing, "inserting, not throwing away")
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertFalse(controller.heldPressStarted)
    }

    /// A slow tap passes the hold delay too. Up in time to be a tap, it keeps
    /// the dictation it opened, and Return finishes it like any tap.
    func testASlowTapKeepsTheDictationItOpened() async {
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording, "the tap must not stop what it just started")
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(fake.stopCount, 0)
        XCTAssertFalse(controller.heldPressStarted)

        controller.handle(.confirm)
        XCTAssertEqual(controller.state, .transcribing)
    }

    /// ⌘C typed slowly: the shortcut reached the app, the take is dropped.
    func testAShortcutAfterTheHoldThrowsTheTakeAway() async {
        let (controller, fake, recorder) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        controller.handle(.rightCommandChord)
        XCTAssertEqual(recorder.current, .off)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    /// Held while a tap-started take runs: no second take, and letting go
    /// stops the first, the way a tap would.
    func testHoldingDuringATakeStopsItWhenLetGo() async {
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        controller.handle(.rightCommandHeld)
        XCTAssertFalse(controller.heldPressStarted)
        XCTAssertEqual(fake.startCount, 1)

        controller.handle(.rightCommandChord)
        XCTAssertEqual(controller.state, .recording, "a chord drops only a take its own press opened")

        controller.handle(.rightCommandReleased)
        XCTAssertEqual(controller.state, .transcribing)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.stopCount, 1)
    }

    /// A hold-to-talk take on the shortcut is the shortcut's to end.
    func testLettingGoOfRightCommandLeavesAShortcutTakeAlone() async {
        let (controller, _, _) = controller()
        controller.beginRecording(submit: false)
        await controller.recordingTask?.value
        controller.handle(.rightCommandReleased)
        XCTAssertEqual(controller.state, .recording)
    }

    /// The microphone failed to open while the key was down. Letting go in
    /// tap time is the end of that same press, not a second try.
    func testAFailedHoldIsNotRetriedWhenTheKeyComesUp() async {
        let (controller, fake, recorder) = controller()
        fake.startError = NSError(domain: "test", code: 1)
        var attempts = 0
        fake.startGate = { attempts += 1 }
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(recorder.current, .off)
    }

    /// Return pressed before letting go finishes the take and ends the press:
    /// the next tap is a new dictation.
    func testReturnBeforeLettingGoEndsThePressToo() async {
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        controller.handle(.confirm)
        XCTAssertFalse(controller.heldPressStarted)
        await controller.recordingTask?.value

        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 2)
    }

    func testAColdHoldAndItsTapStartExactlyOneRecording() async {
        let (controller, fake, _) = controller()
        fake.ready = false
        controller.handle(.rightCommandHeld)
        XCTAssertTrue(controller.heldPressStarted)
        controller.handle(.rightCommandTap)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertFalse(controller.heldPressStarted)
        controller.handle(.cancel)
        await controller.recordingTask?.value
    }

    func testHoldingIsSwitchedOffWithTheTap() async {
        UserDefaults.standard.set(false, forKey: RightCommandTrigger.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }

    func testTheMasterSwitchBlocksHoldingToo() async {
        UserDefaults.standard.set(false, forKey: DictationEnabled.key)
        let (controller, fake, _) = controller()
        controller.handle(.rightCommandHeld)
        await controller.recordingTask?.value
        XCTAssertEqual(fake.startCount, 0)
    }
}
