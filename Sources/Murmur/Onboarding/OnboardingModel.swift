import AppKit
@preconcurrency import AVFoundation
import Foundation
import KeyboardShortcuts
import MurmurKit
import Observation
import PostHog
import SwiftUI

/// App-side `@Observable` that drives the onboarding window. Wraps the pure
/// `OnboardingFlow.State`, delegates every transition/gate to `OnboardingFlow`,
/// and owns the real subsystems (mic, accessibility, models, examples). Reuses
/// the already-warmed `RecordingSession` from `DictationController` so the
/// examples do not spin up a second pipeline.
@MainActor
@Observable
final class OnboardingModel {
    static let didOnboardKey = "murmur.didOnboard"
    /// The same keys `DictationController` reads, so the tour's corrector switch
    /// is the Settings switch.
    static let correctorKey = "speechPostProcessingEnabled"
    static let correctorModelKey = "speechPostProcessingModel"

    var flow = OnboardingFlow.State()
    var finished = false
    var downloadError: String?
    var preparationProgress: RecordingSession.Preparation?

    /// Called once the user completes onboarding — the AppDelegate uses it to boot
    /// the live menu app (mic now granted, models now cached). Set before launch.
    var onFinished: (() -> Void)?

    /// Bring the onboarding window back to the front. A TCC permission dialog steals
    /// focus and, for a menu-bar (`.accessory`) app with no Dock icon, leaves the
    /// setup window buried behind other apps — so we re-front it after the mic prompt.
    var onReactivate: (() -> Void)?

    /// Guards `startDownload` so a Retry never spawns two concurrent downloads.
    @ObservationIgnored private var downloadStarted = false

    private let session: any RecordingSessioning
    @ObservationIgnored private weak var controller: DictationController?
    private(set) var ownsSession = false
    @ObservationIgnored var isTourFocused: () -> Bool = { true }
    @ObservationIgnored private var ownershipTask: Task<Void, Never>?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var ownershipGeneration = 0
    @ObservationIgnored private var eventsBorrowed = false

    /// Polls AX trust after the user asked for it — there's no notification for
    /// Accessibility-trust changes, so we have to ask.
    @ObservationIgnored private var accPollTimer: Timer?

    let micTest = MicLevelMonitor()

    init(session: any RecordingSessioning, controller: DictationController? = nil) {
        self.session = session
        self.controller = controller
    }

    // MARK: navigation

    var step: OnboardingFlow.Step { flow.step }

    var canContinue: Bool {
        if step.isExample, tryListening || tryBusy { return false }
        return OnboardingFlow.canContinue(flow)
    }
    var showBack: Bool { step != .welcome && !finished }

    /// The current push-to-talk shortcut, for the Done screen.
    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description
            ?? KeyboardShortcuts.Name.dictate.defaultShortcut?.description ?? ""
    }

    func next() {
        guard canContinue else { return }
        if step == .done { finish(); return }
        go(to: OnboardingFlow.next(step))
    }
    func back() { go(to: OnboardingFlow.back(step)) }

    /// The stepper jumps back to any step already passed.
    func jump(to target: OnboardingFlow.Step) {
        guard target.rawValue < step.rawValue else { return }
        go(to: target)
    }

    private func go(to target: OnboardingFlow.Step) {
        guard target != step else { return }
        leaveStep()
        flow.step = target
    }

    /// Everything a step started stops when the user leaves it, so an example's
    /// recording or error never leaks into the next step.
    private func leaveStep() {
        micTest.stop()
        stopAccessibilityPolling()
        if step.isExample { tryEnd(discard: true); take += 1; tryReset(); tryPhase = .idle }
        if step == .caret {
            controller?.hud.dismiss(); controller?.companion.dismiss()
            controller?.keyCaptureSink?.setCapture(.off)
            heldDemoPress = false
            caretNeedsFocus = false
        }
    }

    func finish() {
        PostHogSDK.shared.capture("onboarding_completed", properties: [
            "accessibility_granted": flow.accessibilityGranted,
        ])
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        if let everyday { UserDefaults.standard.set(everyday.rawValue, forKey: ModelSetting.key) }
        finished = true
        leaveStep()
        Task { await releaseTourSession(); onFinished?() }
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
        tryReset()
        everyday = nil
        // The models are usually already on disk from the first run, so show the
        // Models step as complete instead of a 0-bar soft-lock.
        downloadStarted = false
        modelsReady = session.isPrepared
        if modelsReady {
            flow.fastFraction = 1
            flow.accurateFraction = 1
        }
    }

    // MARK: permissions — microphone (hard gate) + accessibility (optional)

    /// Ask for microphone access; the system shows its dialog on first call and
    /// returns the cached answer after. Reflects the result into the flow gate.
    func requestMic() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                self.flow.micGranted = ok
                self.micDenied = !ok
                if ok { PostHogSDK.shared.capture("mic_permission_granted") }
                self.onReactivate?()   // the TCC dialog stole focus — pull the window back
            }
        }
    }

    /// The user turned microphone access off earlier; only System Settings can
    /// turn it back on.
    private(set) var micDenied = false

    /// Show the Accessibility-trust prompt (deep-links to System Settings), then
    /// poll until the user flips it on — there's no AX-trust notification.
    func promptAccessibility() {
        _ = Accessibility.prompt()
        startAccessibilityPolling()
    }

    /// Reflect already-granted permissions when a screen appears, so a returning
    /// user sees them granted without re-prompting.
    func refreshPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        flow.micGranted = status == .authorized
        micDenied = status == .denied || status == .restricted
        flow.accessibilityGranted = Accessibility.isTrusted
    }

    private func startAccessibilityPolling() {
        guard accPollTimer == nil else { return }
        accPollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                let trusted = Accessibility.isTrusted
                let wasGranted = self.flow.accessibilityGranted
                self.flow.accessibilityGranted = trusted
                if trusted && !wasGranted { PostHogSDK.shared.capture("accessibility_permission_granted") }
                if self.flow.accessibilityGranted { self.stopAccessibilityPolling() }
            }
        }
    }

    func stopAccessibilityPolling() {
        accPollTimer?.invalidate()
        accPollTimer = nil
    }

    // MARK: microphone list and test

    private(set) var microphones: [MicrophoneDevice] = []
    @ObservationIgnored var availableMicrophones: () -> [MicrophoneDevice] = { AudioInputDevices.available() }
    /// Name of the chosen input that went away, shown until another is picked.
    private(set) var disconnectedMicrophone: String?

    /// The saved input (`MicrophoneSetting`), mirrored so the list redraws.
    var microphoneUID = UserDefaults.standard.string(forKey: MicrophoneSetting.defaultsKey)
        ?? MicrophoneSetting.systemDefaultUID {
        didSet {
            guard microphoneUID != oldValue else { return }
            UserDefaults.standard.set(microphoneUID, forKey: MicrophoneSetting.defaultsKey)
            disconnectedMicrophone = nil
            if micTest.running { micTest.start(uid: MicrophoneSetting.currentUID) }
        }
    }

    /// The input a recording will use right now, by name.
    var microphoneName: String {
        if let device = microphones.first(where: { $0.uid == microphoneUID }) { return device.name }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "System default")
    }

    func refreshMicrophones() {
        guard !tryListening, !tryBusy else { return }
        for device in microphones { seenMicrophoneNames[device.uid] = device.name }
        microphones = availableMicrophones()
        let current = UserDefaults.standard.string(forKey: MicrophoneSetting.defaultsKey) ?? MicrophoneSetting.systemDefaultUID
        let valid = AudioInputDevices.sanitizedUID(current, devices: microphones)
        guard current != valid else { microphoneUID = current; return }
        // The chosen input went away: recordings now use the system default.
        microphoneUID = valid
        disconnectedMicrophone = seenMicrophoneNames[current] ?? String(localized: "The selected microphone")
    }

    /// Names seen in this session, so a device that vanished can still be named.
    @ObservationIgnored private var seenMicrophoneNames: [String: String] = [:]

    func toggleMicTest() {
        if micTest.running { micTest.stop() } else { micTest.start(uid: MicrophoneSetting.currentUID) }
    }

    // MARK: models — real preparation progress

    /// Prepare the same speech profile used by the main application. The shared
    /// session owns model downloads and warm-up; onboarding only presents progress.
    func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        downloadError = nil
        preparationProgress = nil
        modelsReady = false
        flow.fastFraction = 0
        flow.accurateFraction = 0
        PostHogSDK.shared.capture("model_download_started")
        acquireTourSession()
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                await ownershipTask?.value
                try Task.checkCancellation()
                let saved = session.onEvent
                session.onEvent = { [weak self] event in
                    saved?(event)
                    guard case let .preparation(progress) = event else { return }
                    self?.preparationProgress = progress
                }
                defer { session.onEvent = saved }
                let profile = try SpeechRecognitionProfile.resolve(language: SpeechLanguage.automatic, mode: .hybrid)
                try await session.prepare(.init(profile: profile, localProvidersOnly: true))
                flow.fastFraction = 1
                flow.accurateFraction = 1
                self.modelsReady = true
                PostHogSDK.shared.capture("model_download_completed")
            } catch {
                self.downloadStarted = false                 // allow Retry, and a restart after a cancel
                guard !Task.isCancelled else { return }
                self.downloadError = error.localizedDescription
                PostHogSDK.shared.capture("model_download_failed", properties: [
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    /// Reset and re-run the preparation after a failure.
    func retryDownload() {
        downloadError = nil
        if flow.fastFraction < 1 { flow.fastFraction = 0 }
        if flow.accurateFraction < 1 { flow.accurateFraction = 0 }
        modelsReady = session.isPrepared
        startDownload()
    }

    // MARK: examples — real dictation inside the tour

    /// Where an example is. The stages come from the session's own events, so
    /// the screen only names work that actually happens.
    enum TryPhase: Equatable {
        case idle, preparing, listening
        case finishing(RecordingSession.FinishingStage)
        case translating
        case done
        case failed
    }

    var tryPhase: TryPhase = .idle
    var tryConfirmed = ""
    var tryPartial = ""
    var tryListening = false
    var tryMicrophoneLive = false
    var tryWorking: Bool { tryBusy }
    var tryTranslation = ""
    /// The live text at release, to show what the accurate pass changed.
    var tryDraft = ""
    /// Escape threw the last take away.
    var tryCancelled = false
    /// The recognized text before the corrector, when the corrector changed it.
    var tryOriginal = ""
    /// What went wrong, in words. `tryErrorDetails` keeps the raw message for Details.
    var tryError: String?
    var tryErrorDetails: String?
    var practiceLanguage = SpeechLanguage.current
    var practiceTranslationTarget = TranslationSetting.off
    /// The everyday mode picked on the Done step; nil keeps the current one.
    var everyday: DictationMode?
    var demoText = String(localized: "Meeting notes. We ship the tour on Friday. Then we check the microphone list.")
    var demoSelection = NSRange(location: 0, length: 0)
    /// Right ⌘ was pressed while the practice field had no insertion point.
    private(set) var caretNeedsFocus = false
    /// The tour's own text view: its caret is read directly, so the lesson works
    /// without Accessibility.
    @ObservationIgnored weak var demoTextView: NSTextView?
    @ObservationIgnored private var insertionRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private var atCaret = false
    @ObservationIgnored private var heldDemoPress = false

    /// The mode each example demonstrates. Steps after the three mode lessons
    /// use Hybrid; none of them changes the everyday mode.
    var practiceMode: DictationMode {
        switch step {
        case .fast: return .fast
        case .accurate: return .accurate
        default: return .hybrid
        }
    }

    /// The corrector is the real setting (Settings › Models).
    var correctorEnabled: Bool { UserDefaults.standard.bool(forKey: Self.correctorKey) }

    /// The translation target, only on the Translation step and only for a
    /// pair that has a route.
    private var practiceTarget: String? {
        guard step == .translation, practiceTranslationTarget != TranslationSetting.off,
              practiceLanguage != SpeechLanguage.automatic,
              LanguagePair.route(from: practiceLanguage, to: practiceTranslationTarget) != nil
        else { return nil }
        return practiceTranslationTarget
    }

    /// True once the Hybrid pipeline is loaded into memory. Observable — so the
    /// example buttons re-enable the moment loading finishes.
    var modelsReady = false
    var tryReady: Bool { modelsReady && !tryBusy }

    /// The controller's HUD `onEvent` handler, parked while an example borrows
    /// `session.onEvent`, and restored when the dictation ends.
    @ObservationIgnored private var savedOnEvent: ((RecordingSession.Event) -> Void)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Bumped per take and on leaving a step: work from an older take that
    /// finishes late must not write into the step now on screen.
    @ObservationIgnored private var take = 0

    /// True while a previous `tryEnd` is still draining `stop()`. Blocks a rapid
    /// re-press from overlapping start()/stop() on the shared session. Observed:
    /// the buttons and status read it.
    private var tryBusy = false

    /// Press: borrow the warmed session, redirect its updates into the step, and
    /// start an utterance in the step's mode.
    func tryStart(atCaret: Bool = false, initialCaret: CaretLocator.Lookup? = nil) {
        guard modelsReady, !tryListening, !tryBusy else { return }
        acquireTourSession()
        guard ownsSession else { return }
        self.atCaret = atCaret
        insertionRange = demoSelection
        tryReset()
        take += 1
        let current = take
        tryPhase = .preparing
        tryListening = true
        tryMicrophoneLive = false
        let microphoneUID = MicrophoneSetting.currentUID
        let mode = practiceMode, target = practiceTarget
        let corrector = correctorEnabled
        let correctorModel = UserDefaults.standard.string(forKey: Self.correctorModelKey) ?? "automatic"
        startTask = Task {
            do {
                await ownershipTask?.value
                try Task.checkCancellation()
                borrowTrialEvents(take: current)
                let language = practiceLanguage
                let profile = try SpeechRecognitionProfile.resolve(language: language, mode: mode)
                try await session.prepare(.init(profile: profile, target: target,
                    postProcessing: corrector, postProcessingModelID: correctorModel, localProvidersOnly: true))
                try Task.checkCancellation()
                try await session.start(microphoneUID: microphoneUID, recordingURL: nil)
                try Task.checkCancellation()
                tryMicrophoneLive = true
                tryPhase = .listening
                if atCaret {
                    controller?.keyCaptureSink?.setCapture(.recording)
                    controller?.hud.begin(lang: SpeechLanguage.badge(for: language), confirmsWithReturn: !heldDemoPress,
                                          style: .caret, initialCaret: initialCaret,
                                          onStop: { [weak self] in self?.tryEnd() })
                }
            } catch {
                tryListening = false; tryMicrophoneLive = false
                restoreTrialEvents()
                controller?.keyCaptureSink?.setCapture(.off)
                guard take == current else { return }
                if Task.isCancelled { tryPhase = .idle } else { fail(error) }
            }
        }
    }

    private func borrowTrialEvents(take current: Int) {
        savedOnEvent = session.onEvent
        eventsBorrowed = true
        session.onEvent = { [weak self] event in
            guard let self, take == current else { return }
            switch event {
            case let .snapshot(snapshot):
                tryConfirmed = snapshot.confirmed.map(\.text).joined(separator: " ")
                tryPartial = snapshot.provisional
                if self.atCaret { controller?.hud.update(confirmed: tryConfirmed, partial: tryPartial) }
            case let .translation(text, _): tryTranslation = text
            case let .finishing(stage): tryPhase = .finishing(stage)
            case .failure(let failure):
                switch failure {
                case .translation(let message):
                    // The recognized text is still good; only the translation failed.
                    tryError = String(localized: "This pair didn’t translate. The recognized text is kept.")
                    tryErrorDetails = message
                case .recognition(let message), .capture(let message):
                    tryError = String(localized: "Couldn’t recognize this recording. Nothing was typed.")
                    tryErrorDetails = message
                case .recording: break
                }
            default: break
            }
        }
    }

    private func restoreTrialEvents() {
        guard eventsBorrowed else { return }
        session.onEvent = savedOnEvent
        savedOnEvent = nil; eventsBorrowed = false
    }

    /// Names the failure in words; the raw message only goes to Details.
    private func fail(_ error: Error) {
        tryPhase = .failed
        if case RecordingSession.LifecycleError.busy = error {
            tryError = String(localized: "Murmator is finishing another dictation. Try again in a moment.")
        } else {
            tryError = String(localized: "Couldn’t start this example. Nothing was recorded.")
        }
        tryErrorDetails = error.localizedDescription
        if atCaret { controller?.hud.dismiss() }
    }

    func tryEnd(discard requested: Bool = false) {
        guard tryListening else { return }
        // Released before the microphone opened: nothing is recorded.
        let releasedEarly = !requested && !tryMicrophoneLive
        let discard = requested || releasedEarly
        tryReleasedEarly = releasedEarly
        tryListening = false
        tryMicrophoneLive = false
        tryBusy = true
        if discard { startTask?.cancel() }
        if atCaret {
            controller?.keyCaptureSink?.setCapture(discard ? .off : .finishing)
            if discard { controller?.hud.dismiss() } else { controller?.hud.finalizing() }
        }
        if discard { tryPhase = .idle } else { tryDraft = [tryConfirmed, tryPartial].filter { !$0.isEmpty }.joined(separator: " ") }
        let hadTarget = practiceTarget != nil
        let current = take
        stopTask = Task {
            if discard { await session.cancel() }
            await startTask?.value
            // A start that finished after the cancel left the session recording.
            if discard, session.state == .recording { await session.cancel() }
            defer {
                restoreTrialEvents()
                tryBusy = false
                stopTask = nil
                controller?.keyCaptureSink?.setCapture(.off)
                if atCaret { controller?.hud.dismiss() }
            }
            guard session.state == .recording else { return }
            do {
                if discard { return }
                if hadTarget { tryPhase = .translating }
                let result = try await session.stop()
                guard take == current else { return }
                let final = result.text
                tryConfirmed = final
                tryPartial = ""
                tryTranslation = result.translation
                tryOriginal = result.originalTranscript?.text ?? ""
                if tryError != nil { tryPhase = hadTarget && !final.isEmpty ? .done : .failed; return }
                if final.isEmpty {
                    tryPhase = .failed
                    tryError = String(localized: "No speech was detected. Nothing was typed.")
                    return
                }
                tryPhase = .done
                if atCaret { insertDemoText(result.translation.isEmpty ? final : result.translation) }
                let wasFirst = !flow.didTry
                flow.didTry = true
                if wasFirst {
                    PostHogSDK.shared.capture("try_it_completed", properties: ["word_count": final.split(separator: " ").count])
                }
            } catch {
                guard take == current, !Task.isCancelled else { return }
                tryPhase = .failed
                tryError = String(localized: "Couldn’t recognize this recording. Nothing was typed.")
                tryErrorDetails = error.localizedDescription
            }
        }
    }

    /// The press ended before the microphone opened.
    private(set) var tryReleasedEarly = false

    /// Clear the example for another attempt.
    func tryReset() {
        tryConfirmed = ""
        tryPartial = ""
        tryTranslation = ""; tryOriginal = ""; tryDraft = ""
        tryError = nil; tryErrorDetails = nil
        tryReleasedEarly = false; tryCancelled = false
        if !tryListening, !tryBusy { tryPhase = .idle }
    }

    /// VoiceOver can't hold a key — double-tap toggles the utterance instead.
    func tryToggle() {
        if tryListening { tryEnd() } else { tryStart() }
    }

    /// The corrector runs as part of a recording, so a switch clears the old
    /// result rather than showing a comparison it did not make.
    func setCorrector(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.correctorKey)
        tryReset()
    }

    func acquireTourSession() {
        guard !ownsSession else { return }
        if let controller, controller.isActive || controller.isStartingRecording {
            tryPhase = .failed
            tryError = String(localized: "Murmator is finishing another dictation. Try again in a moment.")
            return
        }
        ownsSession = true
        controller?.reserveForOnboarding()
        ownershipGeneration &+= 1
        let generation = ownershipGeneration
        let pendingClose = closingTask
        controller?.releaseOnboardingSession = { [weak self] in await self?.releaseTourSession() }
        controller?.onboardingGestureHandler = { [weak self] gesture in
            guard let self, self.ownsSession, self.isTourFocused() else { return false }
            guard self.step == .caret else {
                if gesture == .rightCommandTap {
                    self.controller?.companion.error(String(localized: "Right ⌘ is taught on the At the caret step."))
                }
                return true
            }
            self.handleDemoGesture(gesture)
            return true
        }
        ownershipTask = Task {
            await pendingClose?.value
            guard ownsSession, ownershipGeneration == generation, !Task.isCancelled else { return }
            await controller?.pauseForOnboarding()
        }
    }

    func releaseTourSession() async {
        ownsSession = false
        ownershipGeneration &+= 1
        ownershipTask?.cancel()
        if let closingTask { await closingTask.value; return }
        let pendingOwnership = ownershipTask, pendingStart = startTask
        let pendingStop = stopTask, pendingDownload = downloadTask
        pendingStart?.cancel(); pendingStop?.cancel(); pendingDownload?.cancel()
        micTest.stop()
        let task = Task {
            await pendingOwnership?.value
            await session.cancel()
            await pendingStart?.value; await pendingStop?.value; await pendingDownload?.value
            restoreTrialEvents()
            tryListening = false; tryMicrophoneLive = false; tryBusy = false
            controller?.keyCaptureSink?.setCapture(.off)
            controller?.hud.dismiss(); controller?.companion.dismiss()
            if !ownsSession { controller?.resumeAfterOnboarding() }
            closingTask = nil
        }
        closingTask = task
        await task.value
    }

    /// The window stays open when another app takes focus, but the take ends:
    /// the on-screen button can't get its release any more, and right ⌘ in the
    /// other app belongs to ordinary dictation.
    func tourLostFocus() {
        if tryListening { tryEnd() }
        controller?.keyCaptureSink?.setCapture(.off)
    }

    /// The window is closing: stop whatever the current step started.
    func leaveCaretDemo() {
        leaveStep()
    }

    func handleDemoGesture(_ gesture: KeyGesture) {
        switch gesture {
        case .rightCommandHeld:
            guard !tryListening, !tryBusy, let lookup = demoCaretLookup() else { return }
            heldDemoPress = true
            tryStart(atCaret: true, initialCaret: lookup)
            if !tryListening { heldDemoPress = false }
        case .rightCommandTap:
            if heldDemoPress { heldDemoPress = false; return }
            if tryListening { tryEnd(); return }
            guard let lookup = demoCaretLookup() else { return }
            tryStart(atCaret: true, initialCaret: lookup)
        case .rightCommandReleased:
            guard heldDemoPress else { return }
            heldDemoPress = false
            tryEnd(discard: !tryMicrophoneLive)
        case .rightCommandChord:
            if heldDemoPress { heldDemoPress = false; tryEnd(discard: true) }
        case .confirm: heldDemoPress = false; tryEnd()
        case .cancel:
            heldDemoPress = false
            let wasListening = tryListening
            tryEnd(discard: true)
            tryCancelled = wasListening
        case .submitWhenDone: break
        }
    }

    /// The insertion point of the practice field, read from the text view itself.
    /// Nil (and a hint on screen) while the field has no focus.
    private func demoCaretLookup() -> CaretLocator.Lookup? {
        guard let view = demoTextView, let window = view.window, window.firstResponder === view else {
            caretNeedsFocus = true
            return nil
        }
        caretNeedsFocus = false
        var actual = NSRange()
        let rect = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: &actual)
        // An empty field has no glyph to measure; let the HUD ask Accessibility.
        guard rect.height > 0 else { return .notFound }
        let caret = CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        let field = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        let font = view.font.map { FieldFont(name: $0.fontName, size: $0.pointSize) }
        return .found(CaretSpot(caret, field: field, font: font))
    }

    func clearCaretFocusHint() { caretNeedsFocus = false }

    /// NSTextView uses UTF-16 ranges. Keep insertion correct around emoji and selections.
    func insertDemoText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = demoText as NSString
        let start = min(max(0, insertionRange.location), source.length)
        let length = min(max(0, insertionRange.length), source.length - start)
        demoText = source.replacingCharacters(in: NSRange(location: start, length: length), with: text)
        demoSelection = NSRange(location: start + (text as NSString).length, length: 0)
    }

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
