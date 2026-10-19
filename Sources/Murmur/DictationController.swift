import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import MurmurKit
import class MurmurCloud.ProviderRecordingSession
import Observation
import PostHog
import os

private let dictationLog = Logger(subsystem: "app.bshk.murmur", category: "dictation")

/// Platform presentation and delivery over the shared iOS/macOS recording session.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case loadingModels
        case unloadingModels
        case modelsUnloaded
        case startingRecording
        case idle
        case recording
        case transcribing
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .modelsUnloaded {
        // Every transition, wherever it happens, tells the key tap what to
        // hold back. One hook rather than a call after each assignment: a
        // missed call would leave Return captured after a dictation ended,
        // and Return would stop working everywhere on the Mac.
        didSet { syncKeyCapture() }
    }
    private(set) var sessionWarning: String?
    /// Memory-only recovery survives a new take and the HUD fading away.
    private(set) var lastOutputText = ""
    private struct PendingDelivery {
        let generation: Int
        let text: String
        let translation: String
        let quality: Bool
        let started = ContinuousClock.now
    }
    @ObservationIgnored private var pendingDelivery: PendingDelivery?
    var isDelivering: Bool { pendingDelivery != nil }
    @ObservationIgnored var accessibilityTrusted: () -> Bool = { Accessibility.isTrusted }
    @ObservationIgnored var pasteTranscript: (String, Bool, @escaping @Sendable (Bool) -> Void) -> TextInjector.Result = {
        TextInjector.paste($0, submit: $1, settled: $2)
    }
    private(set) var hasCapturedAudio = false
    private(set) var modelPreparation: RecordingSession.Preparation?

    /// Pinned since the Insert-mode setting was removed. Kept in the events rather
    /// than dropped so historical PostHog series stay continuous.
    private static let insertModeAnalyticsValue = "inField"

    var session: any RecordingSessioning
    let hud = HUDController()
    let companion = DictationCompanion()
    /// Captions render here, not in the HUD — see `CaptionsOverlay`.
    let captionsOverlay = CaptionsOverlay()
    @ObservationIgnored var captionSource: String?
    @ObservationIgnored var captionTarget: String?
    @ObservationIgnored var recordingTask: Task<Void, Never>?
    @ObservationIgnored var captionTranslateTask: Task<Void, Never>?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var stopAfterStart = false
    @ObservationIgnored private var captureFailed = false

    /// Right ⌘, Return and Escape. Installed by `bootstrap`, never in tests:
    /// a system-wide event tap has no place in a unit test, so they set
    /// `keyCaptureSink` to a recorder instead.
    @ObservationIgnored private var keyTap: GlobalKeyTap?
    @ObservationIgnored var onboardingGestureHandler: ((KeyGesture) -> Bool)?
    @ObservationIgnored var releaseOnboardingSession: (() async -> Void)?
    private(set) var onboardingOwnsSession = false
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored var keyCaptureSink: KeyCaptureSink?
    /// Whether this session finishes on Return and cancels on Escape. Latched
    /// at start: every tap-on dictation does (there is no key held down to
    /// release, so Return is the natural "done"), hold-to-talk and captions
    /// do not. A talk runs for an hour while the speaker types, and a held
    /// chord already says when it ends.
    @ObservationIgnored private(set) var confirmsWithReturn = false
    /// Escape was pressed: the transcript is dropped rather than inserted.
    @ObservationIgnored private var discarding = false
    /// Return was pressed again while the text was still being finalised.
    /// The user meant "and send it", so Return is pressed after the paste.
    @ObservationIgnored private(set) var submitRequested = false
    /// Right ⌘ is down and its `.rightCommandHeld` was acted on: the gesture
    /// that ends this press (tap, release, chord - or Return / Escape pressed
    /// before letting go) belongs to what the hold started, not to a new take.
    /// Cleared by that gesture rather than by the recording ending, so a press
    /// whose start failed is not taken for a fresh tap when it comes up.
    @ObservationIgnored private(set) var heldPressStarted = false
    /// Why the take being thrown away was thrown away, for analytics.
    @ObservationIgnored private var cancelReason = CancelReason.escape
    /// The paste has been posted and the app has not necessarily applied it
    /// yet. Return stays held back through that window - the same one
    /// `TextInjector` waits out before its own Return - or a press in it would
    /// send the chat field without the text.
    @ObservationIgnored private(set) var pasteSettling = false
    /// Stamps each recording, so the end of one paste's settle window cannot
    /// release the capture a newer recording already owns.
    @ObservationIgnored private(set) var recordingGeneration = 0
    /// The take whose paste a held-back Return still waits for, its window
    /// cut short by a new recording: it goes when that paste lands, or not.
    @ObservationIgnored private var returnAwaitingPaste: Int?
    /// The settling paste already ends with its own Return.
    @ObservationIgnored private var settleAlreadySubmits = false
    /// Sends a Return held back during the settle window. A seam for tests: the
    /// real one posts a key event into whatever app the developer has focused.
    @ObservationIgnored var pressReturn: () -> Void = { TextInjector.pressReturn() }

    /// What the key tap should hold back right now. Derived, not stored, so it
    /// cannot drift from `state`.
    var keyCapture: KeyCapture {
        guard confirmsWithReturn else { return .off }
        switch state {
        case .recording: return .recording
        case .startingRecording: return stopAfterStart ? .finishing : .recording
        case .transcribing: return discarding ? .off : .finishing
        case .transcribed where pasteSettling: return .finishing
        default: return .off
        }
    }

    private func syncKeyCapture() { keyCaptureSink?.setCapture(keyCapture) }

    /// The language *this utterance* was recognised in, latched when the
    /// recogniser was started.
    ///
    /// The same pinning captions already do, and for a stronger reason. The
    /// target may be re-read at stop - it is a choice about the output, and
    /// honouring the latest one is a feature. The source is not a choice: it
    /// is a fact about what the recogniser was told, already baked into the
    /// text it produced. Re-reading it at stop meant that changing Language
    /// mid-utterance (easy in toggle mode, where the menu stays reachable)
    /// translated Russian speech as though it were German - a wrong answer
    /// with no error anywhere. Not `private`: tests assert the latch survives
    /// a mid-utterance picker change.
    @ObservationIgnored var dictationSource: String?

    /// What a finished utterance's translation routes *from*.
    ///
    /// The session's latch, never the live picker. One place rather than an
    /// expression at the call site so the rule has somewhere to be stated and
    /// somewhere to be tested. The fallback covers only a stop with no start
    /// behind it, where there is no recognised text to be wrong about.
    var translationSource: String { dictationSource ?? SpeechLanguage.current }

    /// The mode this utterance actually ran in, latched at start.
    ///
    /// Two things go wrong without it, and only one needs a user to do
    /// anything. First, the same staleness as `dictationSource`: switching
    /// Model mid-utterance made the completion event describe a mode that
    /// never ran. Second, and with nobody touching anything -
    /// `beginRecording` runs `ModelSetting.current.effective(for:)`, which
    /// downgrades Fast and Hybrid to Accurate for the languages with no live
    /// draft. `dictation_started` logs that effective mode; reading the raw
    /// setting again at stop meant every Japanese, Korean, Chinese, Arabic
    /// and Vietnamese utterance reported started=accurate and
    /// completed=hybrid. The routing matrix is exactly what these two events
    /// exist to measure, so the one field that says which lane ran cannot be
    /// the field that says which lane was asked for.
    @ObservationIgnored var dictationMode: DictationMode?

    /// The mode a finished utterance is reported as having run in.
    ///
    /// Fallback only covers a stop with no start behind it, where nothing ran
    /// to be described.
    var completedModelMode: DictationMode { dictationMode ?? ModelSetting.current }
    /// The in-flight model fetch, so scrubbing through the picker cannot leave
    /// a queue of downloads for languages nobody chose.
    @ObservationIgnored private var translationPrepare: Task<Void, Never>?
    /// Observed by the popover to draw the download bar.
    private(set) var translationDownload: TranslationDownload?
    private(set) var translationPreparationError: String?
    private(set) var isPreparingTranslation = false
    /// Stamps each preparation so a cancelled one cannot repaint or clear the
    /// bar that now belongs to a later choice.
    @ObservationIgnored private var translationGeneration = 0

    init(session: (any RecordingSessioning)? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        self.session = session ?? ProviderRecordingSession(modelsRoot: root,
            translationRoot: TranslationModels.root, memoryLimit: Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6))
        if self.session.isPrepared { state = .idle }
        connectSession()
    }

    var dictationSession: any RecordingSessioning { session }

    private func connectSession() {
        session.onEvent = { [weak self] event in self?.receive(event) }
    }

    func receive(_ event: RecordingSession.Event) {
        switch event {
        case let .capture(frames, _):
            if frames > 0, state == .startingRecording || state == .recording { hasCapturedAudio = true }
        case let .snapshot(snapshot):
            guard state == .recording || state == .transcribing else { return }
            echo(snapshot.confirmed.map(\.text).joined(separator: " "), snapshot.provisional)
        case let .translation(line, _):
            guard captionsRunning, state == .recording else { return }
            captionsOverlay.showTranslation(line)
        case let .preparation(progress):
            if state == .loadingModels || state == .unloadingModels {
                modelPreparation = progress
                state = progress.stage == .unloading ? .unloadingModels : .loadingModels
            }
            companion.updatePreparation(modelPreparationStatus, fraction: progress.fraction)
            if progress.stage == .translation, translationPreparationError == nil,
               let fraction = progress.fraction {
                translationDownload = .init(fraction: fraction, receivedBytes: 0, totalBytes: 0)
            }
        case let .failure(failure):

            switch failure {
            case let .recognition(message):
                sessionWarning = message
            case let .translation(message):
                sessionWarning = message
                if captionsRunning { captionsOverlay.showTranslation("") }
                dictationLog.error("Translation failed")
            case let .capture(message):
                sessionWarning = message
                captureFailed = true
                endRecording()
            case let .recording(message):

                dictationLog.error("Diagnostic audio failed")
            }
        case .state(.preparing):
            if !isActive, !isPreparing, !starting { state = .loadingModels }
        case .state(.ready):
            if !isPreparing, !starting, isManagingModels {
                modelPreparation = nil
                state = .idle
            }
        case .state(.idle):
            if !isPreparing, !starting, isManagingModels, modelPreparation?.stage == .unloading {
                modelPreparation = nil
                state = .modelsUnloaded
            }
        case let .finishing(stage):
            guard state == .transcribing, !discarding else { return }
            switch stage {
            case .recognition: companion.finishing(String(localized: "Refining the transcript…"))
            case .languageDetection: companion.finishing(String(localized: "Detecting the final language…"))
            case .textEditing: companion.finishing(String(localized: "Correcting spelling and grammar…"))
            }
        default: break
        }
    }

    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var preparationGeneration = 0

    /// Which pipeline owns the live session, and whether its stop comes from a
    /// second tap rather than the key release. Both latched at start so a mode
    /// change mid-session cannot strand a running mic.
    @ObservationIgnored private var captionsRunning = false
    /// Readable so tests can prove a menu start latches tap-off.
    @ObservationIgnored private(set) var latchedToggle = false

    /// Whether this utterance ends with a Return. Latched when recording begins and
    /// left alone until it ends: in hold mode there is no separate stop gesture to
    /// carry the intent, so letting the *stopping* key decide would make the two
    /// trigger modes behave differently for the same pair of shortcuts.
    @ObservationIgnored private var submitOnFinish = false

    private(set) var microphones: [MicrophoneDevice] = []

    /// Refresh when the popover opens. Core Audio device IDs are transient, so the
    /// UI stores UIDs and rebuilds the current catalog each time it is shown.
    /// Returns the selection the Picker should display; a missing device visibly
    /// falls back to System Default.
    @discardableResult
    func refreshMicrophones(preferredUID: String) -> String {
        microphones = AudioInputDevices.available()
        return AudioInputDevices.sanitizedUID(preferredUID, devices: microphones)
    }

    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description
            ?? KeyboardShortcuts.Name.dictate.defaultShortcut?.description ?? ""
    }

    /// Whether a right-⌘ tap starts a dictation right now: switched on, and the
    /// tap able to see the key at all, which takes Accessibility.
    var rightCommandWorks: Bool { RightCommandTrigger.isEnabled && Accessibility.isTrusted }

    /// Every way to start, for the menu: the key that needs no chord first.
    var triggerLabel: String {
        rightCommandWorks ? "\(RightCommandTrigger.label) · \(shortcutLabel)" : shortcutLabel
    }

    /// What the Mac can recognize: Parakeet's languages. The translation list is
    /// wider - Whisper on the iPhone covers Catalan or Belarusian, and Arabic has
    /// its own model there - and offering those here gave text in the wrong
    /// language.
    var supportedLanguageCodes: [String] { [SpeechLanguage.automatic] + SpeechModelChoice.parakeetLanguages.sorted() }

    /// The binding actually held for this utterance, so the HUD names the key the
    /// user is on rather than a guess. An unbound send-shortcut falls back to the
    /// plain one — `shortcutLabel` already carries the last-resort default.
    private func activeShortcutLabel(submit: Bool) -> String {
        guard submit else { return shortcutLabel }
        return KeyboardShortcuts.getShortcut(for: .dictateAndSend)?.description ?? shortcutLabel
    }

    /// Typing into other apps needs Accessibility (the hotkey itself does not).
    var needsAccessibilityToType: Bool { !Accessibility.isTrusted }

    var statusLine: String {
        if let sessionWarning { return sessionWarning }
        switch state {
        case .loadingModels: return modelPreparationStatus
        case .unloadingModels: return String(localized: "Freeing model memory…")
        case .modelsUnloaded: return String(localized: "Models are not loaded")
        case .startingRecording: return String(localized: "Starting microphone…")
        case .idle:
            return rightCommandWorks
                ? "Idle — tap \(RightCommandTrigger.label) or hold \(shortcutLabel)"
                : "Idle — hold \(shortcutLabel)"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case let .transcribed(t): return t.isEmpty ? "…(no speech detected)" : t
        case let .error(m): return "Error: \(m)"
        }
    }

    /// Compact status for the menu popover.
    var shortStatus: String {
        if let sessionWarning { return sessionWarning }
        switch state {
        case .loadingModels: return modelPreparationStatus
        case .unloadingModels: return String(localized: "Freeing memory…")
        case .modelsUnloaded: return String(localized: "Models are not loaded")
        case .startingRecording: return String(localized: "Starting microphone…")
        case .idle, .transcribed:
            return session.isPrepared ? "Ready" : String(localized: "Models are not loaded")
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case let .error(m): return m
        }
    }

    /// True while a dictation is in flight (drives the popover pulse dot).
    var isActive: Bool {
        state == .recording || state == .transcribing || state == .startingRecording
    }

    var isManagingModels: Bool { state == .loadingModels || state == .unloadingModels }
    var isStartingRecording: Bool { starting }
    var canChangeModels: Bool { !isActive && !starting && !onboardingOwnsSession }
    var loadedModelName: String? {
        guard session.isPrepared, let profile = session.configuration?.profile else { return nil }
        if let providerSession = session as? ProviderRecordingSession { return providerSession.residentSpeechModelName }
        let preview = profile.previewBackend == .whistle ? "Whistle" : "Nemotron"
        switch profile.mode {
        case .fast: return preview
        case .accurate: return profile.model.title
        case .hybrid: return "\(preview) + \(profile.model.title)"
        }
    }
    var modelPreparationStatus: String {
        switch modelPreparation?.stage {
        case .unloading: return String(localized: "Freeing model memory…")
        case .translation: return String(localized: "Preparing translation…")
        case .warmup: return String(localized: "Warming up recognition…")
        case .speech: return String(localized: "Loading speech model…")
        case .textModel: return String(localized: "Loading text corrector…")
        case nil: return String(localized: "Preparing models…")
        }
    }

    var mascotMood: MascotMood {
        switch state {
        case .recording: return .listening
        case .transcribing: return .transcribing
        case .error: return .error
        case .loadingModels, .unloadingModels, .startingRecording: return .transcribing
        case .transcribed: return .success
        case .idle, .modelsUnloaded: return .idle
        }
    }

    /// Everything `bootstrap` performs, as data.
    ///
    /// Declarative because the failure being guarded against is an *omission*,
    /// and an omission inside a function body is invisible to any test that
    /// cannot run that body. `bootstrap` registers Carbon hotkeys, prompts for
    /// the microphone and loads multi-gigabyte models — none of which belongs
    /// in a unit test. A list can be inspected without being executed.
    enum StartupStep: CaseIterable {
        case transcriptEcho
        case hotkeys
        /// Right ⌘ to start, Return to insert, Escape to cancel. A step of its
        /// own because it is not a Carbon hotkey: a lone modifier cannot be
        /// registered as one, and holding Return back takes an event tap.
        case keyTap
        case microphonePermission
        case currentMode
        /// Resume an interrupted or never-started model fetch. Without this, a
        /// target chosen in a previous run whose download did not finish would
        /// never resume: the only trigger is the picker changing, and
        /// reopening the app does not change it. The user would dictate and
        /// quietly get untranslated text.
        case translationModels
    }

    /// The steps actually run, kept separate from `allCases` on purpose: the
    /// pair makes "declared but never performed" a detectable state rather
    /// than a silent gap, which is exactly how translation preparation went
    /// missing at launch in the first place.
    static let startupSteps: [StartupStep] = [
        .transcriptEcho,
        .hotkeys,
        .keyTap,
        .microphonePermission,
        .currentMode,
        .translationModels,
    ]

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        for step in Self.startupSteps { apply(step) }
    }

    /// Transfer model ownership only after the main application's native work drains.
    func reserveForOnboarding() { onboardingOwnsSession = true }

    func pauseForOnboarding() async {
        onboardingOwnsSession = true
        if preparationTask != nil || translationPrepare != nil {
            releaseModels(includingRecordingStart: false)
            await preparationTask?.value
        }
    }

    func resumeAfterOnboarding() {
        onboardingOwnsSession = false
        onboardingGestureHandler = nil
        releaseOnboardingSession = nil
        syncKeyCapture()
        if !starting, !isActive {
            state = session.isPrepared ? .idle : .modelsUnloaded
            if bootstrapped { prepareCurrentMode(); prepareTranslation() }
        }
    }

    private func apply(_ step: StartupStep) {
        switch step {
        case .transcriptEcho:
            connectSession()
        case .hotkeys:
            KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown(submit: false) }
            KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
            KeyboardShortcuts.onKeyDown(for: .dictateAndSend) { [weak self] in self?.hotkeyDown(submit: true) }
            KeyboardShortcuts.onKeyUp(for: .dictateAndSend) { [weak self] in self?.hotkeyUp() }
        case .keyTap:
            installKeyTap()
        case .microphonePermission:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .currentMode:
            prepareCurrentMode()                    // load only what this mode needs
        case .translationModels:
            prepareTranslation()                    // returns at once when present
        }
    }

    func requestAccessibility() { Accessibility.prompt() }

    /// The tour and the live app share one event tap; finishing setup must not
    /// install a second listener for the same right-⌘ press.
    func installKeyTap() {
        guard keyTap == nil else { return }
        let tap = GlobalKeyTap { [weak self] gesture in self?.handle(gesture) }
        keyTap = tap
        keyCaptureSink = tap
        tap.start()
    }

    /// Re-load when the Model or App-mode setting changes (popover) — pulls in the
    /// newly selected mode's models so the next press starts instantly.
    ///
    /// Never while a session is live: preparation moves `state` to `.loadingModels`,
    /// which would strand the running mic (stop only fires from `.recording`).
    func prepareCurrentMode() {
        guard canChangeModels else { return }
        if ModelLoadingPolicy.current == .onDemand {
            if state != .unloadingModels, session.isPrepared || isPreparing || isPreparingTranslation { releaseModels() }
            return
        }
        prepare(mode: ModelSetting.current)
    }

    /// Prepares the selected pair through the common owner before the next recording.
    func prepareTranslation() {
        guard !onboardingOwnsSession else { return }
        if ModelLoadingPolicy.current == .onDemand, !isActive {
            if state != .unloadingModels, session.isPrepared || isPreparing || isPreparingTranslation { releaseModels() }
            return
        }
        let previousPreparation = translationPrepare
        previousPreparation?.cancel()
        translationDownload = nil
        let previousError = translationPreparationError
        translationPreparationError = nil
        isPreparingTranslation = false
        translationPrepare = nil
        translationGeneration &+= 1
        let generation = translationGeneration
        if captionsRunning, state == .recording {
            updateCaptionTarget()
            return
        }
        guard !isActive else { return }
        let source = SpeechLanguage.current
        guard let target = TranslationSetting.target,
              TranslationSetting.canTranslate(from: source) else {
            if let previousPreparation {
                // Keep ownership until cancelled native/download work drains.
                // A new recording or model choice must still be able to await it.
                isPreparingTranslation = true
                translationPrepare = Task { [weak self] in
                    await previousPreparation.value
                    guard let self, translationGeneration == generation, !Task.isCancelled else { return }
                    translationPrepare = nil
                    isPreparingTranslation = false
                    translationDownload = nil
                    modelPreparation = nil
                    if !isActive, !starting, !isPreparing {
                        state = session.isPrepared ? .idle : .modelsUnloaded
                    }
                }
            } else if previousError != nil, !isPreparing {
                sessionWarning = nil
                state = session.isPrepared ? .idle : .modelsUnloaded
            }
            return
        }
        let pendingSpeech = preparationTask
        isPreparingTranslation = true
        sessionWarning = nil
        state = .loadingModels
        translationPrepare = Task { [weak self] in
            guard let self else { return }
            defer {
                if translationGeneration == generation {
                    translationDownload = nil
                    isPreparingTranslation = false
                    translationPrepare = nil
                    modelPreparation = nil
                }
            }
            await previousPreparation?.value
            await pendingSpeech?.value
            guard !Task.isCancelled, translationGeneration == generation else { return }
            do {
                let profile = try WhistleSetting.profile(language: source, mode: ModelSetting.current)
                try await session.prepare(.init(profile: profile, target: target,
                    postProcessing: AppMode.current != .captions && UserDefaults.standard.bool(forKey: "speechPostProcessingEnabled"),
                    postProcessingModelID: UserDefaults.standard.string(forKey: "speechPostProcessingModel"),
                    preloadPostProcessing: ModelLoadingPolicy.current == .atLaunch))
                guard translationGeneration == generation, !Task.isCancelled, !isActive, !starting else { return }
                state = .idle
            } catch is CancellationError {
            } catch {
                if translationGeneration == generation, !Task.isCancelled, !isActive {
                    modelPreparation = nil
                    let message = Self.translationErrorMessage(error)
                    translationPreparationError = message
                    state = .error("Translation unavailable: \(message)")
                }
                dictationLog.error("Translation preparation failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            }
        }
    }

    var canRetryTranslationPreparation: Bool {
        translationPreparationError != nil && !isPreparingTranslation && canChangeModels
    }

    func retryTranslationPreparation() {
        guard canRetryTranslationPreparation else { return }
        prepareTranslation()
    }

    /// The picker owns the desired target; the shared session owns cancellation,
    /// cache invalidation and stale-result protection.
    func updateCaptionTarget() {
        captionsOverlay.setTranslationTarget(captionSource.map(TranslationSetting.badge(dictating:)) ?? "")
        let target = captionSource.flatMap { TranslationSetting.canTranslate(from: $0) ? TranslationSetting.target : nil }
        captionTarget = target
        captionsOverlay.showTranslation("")
        let previous = captionTranslateTask
        previous?.cancel()
        captionTranslateTask = Task { [session] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await session.setTranslation(target: target, priority: .quality)
            }
            catch is CancellationError {} catch {
                dictationLog.error("Translation failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            }
        }
    }

    /// Presentation progress; the common session owns downloads and warm-up.
    struct TranslationDownload: Equatable {
        var fraction: Double
        var receivedBytes: Int64
        var totalBytes: Int64
    }

    // MARK: quality translation model

    /// In-flight quality-model fetches, keyed by direction. A dictionary, not
    /// a single slot: the fast tier's download engine already lets ru-en and
    /// en-ru fetch concurrently (its dedup key is the install directory, which
    /// differs per pair), and a single flat `Task?`/`TranslationDownload?`
    /// here would either misattribute one pair's progress bar to whichever
    /// pair the picker happens to show, or silently refuse a second
    /// direction's tap while the first is still running - both worse than the
    /// two or three dictionary entries this ever actually holds.
    @ObservationIgnored private var qualityDownloadTasks: [LanguagePair: Task<Void, Never>] = [:]
    @ObservationIgnored private var qualityDownloadGenerations: [LanguagePair: Int] = [:]
    /// Observed by the popover to draw the quality download bar for the pair
    /// it is currently showing.
    private var qualityDownloads: [LanguagePair: TranslationDownload] = [:]
    /// Set on failure, cleared on the next attempt for that pair. A settings
    /// screen showing nothing after a tap reads as broken, not as "nothing
    /// happened".
    private var qualityDownloadErrors: [LanguagePair: String] = [:]

    func qualityDownload(for pair: LanguagePair) -> TranslationDownload? {
        qualityDownloads[pair]
    }

    func qualityDownloadError(for pair: LanguagePair) -> String? {
        qualityDownloadErrors[pair]
    }

    /// The direct pair the quality control acts on right now, or nil when
    /// there is nothing to offer: automatic detection has no source, no
    /// target is chosen, or the pair only routes through a pivot. The quality
    /// tier has no converted pivot leg yet, so a button that always failed
    /// would be worse than no button.
    var qualityCandidatePair: LanguagePair? {
        guard let target = TranslationSetting.target else { return nil }
        let source = SpeechLanguage.current
        guard source != SpeechLanguage.automatic,
              case let .direct(pair)? = LanguagePair.route(from: source, to: target)
        else { return nil }
        return pair
    }

    /// Whether MurmurKit has a CTranslate2 conversion for this pair at all,
    /// regardless of whether it is installed yet. Most directions do not -
    /// only ru-en and en-ru are converted so far - and the control should not
    /// appear for those rather than offer a download that can only fail.
    func qualityModelIsOffered(for pair: LanguagePair) -> Bool {
        TranslationDownloader.expectedDownloadBytes(for: pair, kind: .quality) != nil
    }

    func qualityModelIsInstalled(for pair: LanguagePair) -> Bool {
        TranslationDownloader.isInstalled(pair: pair, in: TranslationModels.root, kind: .quality)
    }

    /// Start (or ignore a repeat tap on) the quality-model download for `pair`.
    /// A different pair already downloading is untouched and keeps running.
    ///
    /// Guarded on the task itself, not on `qualityDownloads[pair]` being nil:
    /// the bar briefly reads nil between the first byte's callback landing and
    /// the task actually starting, and a second tap in that gap must still be
    /// a no-op rather than a second fetch of the same 250 MB.
    func downloadQualityModel(for pair: LanguagePair) {
        guard qualityDownloadTasks[pair] == nil else { return }
        guard !qualityModelIsInstalled(for: pair) else { return }
        let generation = (qualityDownloadGenerations[pair] ?? 0) &+ 1
        qualityDownloadGenerations[pair] = generation
        qualityDownloadErrors[pair] = nil
        let root = TranslationModels.root
        qualityDownloadTasks[pair] = Task.detached(priority: .utility) { [weak self] in
            do {
                _ = try await TranslationDownloader.download(
                    pair: pair, into: root, kind: .quality,
                    onProgress: { progress in
                        guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                        self.qualityDownloads[pair] = TranslationDownload(
                            fraction: progress.fraction,
                            receivedBytes: progress.receivedBytes,
                            totalBytes: progress.totalBytes)
                    })
                await MainActor.run { [weak self] in
                    guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                    self.qualityDownloads[pair] = nil
                    self.qualityDownloadTasks[pair] = nil
                }
                PostHogSDK.shared.capture("quality_model_downloaded", properties: [
                    "pair": pair.description,
                ])
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.qualityDownloadGenerations[pair] == generation else { return }
                    self.qualityDownloads[pair] = nil
                    self.qualityDownloadTasks[pair] = nil
                    self.qualityDownloadErrors[pair] = Self.translationErrorMessage(error)
                }
                PostHogSDK.shared.capture("quality_model_download_failed", properties: [
                    "pair": pair.description,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    /// Decode typed download failures once for automatic preparation and the
    /// explicit quality download; raw enum descriptions hide the actual cause.
    private static func translationErrorMessage(_ error: Error) -> String {
        if let failure = error as? TranslationService.Failure {
            return "\(failure.leg): \(translationErrorMessage(failure.underlying))"
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet:
                return "You are offline. Check your connection and try again."
            case .networkConnectionLost:
                return "The network connection was lost. Check your connection and try again."
            case .timedOut:
                return "The download timed out. Check your connection and try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Could not connect to the model server. Try again."
            default: break
            }
        }
        guard let err = error as? TranslationDownloader.Err else {
            return error.localizedDescription
        }
        switch err {
        case .insufficientSpace:
            return "Not enough disk space for the translation model. Free some space and try again."
        case let .httpStatus(status, _):
            return "The model server returned HTTP \(status). Try again."
        case .digestMismatch:
            return "The downloaded model failed verification. Try again."
        case .notGzip, .inflateFailed:
            return "The downloaded model could not be unpacked. Try again."
        case .unpinnedDirection:
            return "No verified translation model exists for this language pair."
        case .qualityDownloadBusy:
            return "Another quality model is downloading \u{2014} try again once it finishes."
        }
    }

    /// Lazily load (download on first run) only the models `mode` needs, surfacing
    /// a loading state. New selections supersede old loads and wait for release.
    private func prepare(mode: DictationMode) {
        let previous = preparationTask
        previous?.cancel()
        preparationGeneration &+= 1
        let generation = preparationGeneration
        let language = SpeechLanguage.current
        isPreparing = true
        sessionWarning = nil
        modelPreparation = nil
        state = previous == nil ? .loadingModels : .unloadingModels
        let pendingTranslation = translationPrepare
        pendingTranslation?.cancel()
        translationGeneration &+= 1
        translationPrepare = nil
        isPreparingTranslation = false
        translationDownload = nil
        preparationTask = Task { @MainActor in
            if previous != nil || pendingTranslation != nil { await session.cancel() }
            await previous?.value
            await pendingTranslation?.value
            guard preparationGeneration == generation, !Task.isCancelled else { return }
            defer {
                if preparationGeneration == generation {
                    isPreparing = false
                    preparationTask = nil
                    modelPreparation = nil
                }
            }
            do {
                let profile = try WhistleSetting.profile(language: language, mode: mode)
                state = .loadingModels
                try await session.prepare(.init(profile: profile,
                    postProcessing: AppMode.current != .captions && UserDefaults.standard.bool(forKey: "speechPostProcessingEnabled"),
                    postProcessingModelID: UserDefaults.standard.string(forKey: "speechPostProcessingModel"),
                    preloadPostProcessing: ModelLoadingPolicy.current == .atLaunch))
                guard preparationGeneration == generation, !Task.isCancelled else { return }
                state = .idle
            } catch {
                guard preparationGeneration == generation, !Task.isCancelled else { return }
                state = .error("model load: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels preparation and waits for native/MLX work to drain before Ready
    /// can be shown or another model can acquire memory. Cached files remain.
    func releaseModels(includingRecordingStart: Bool = true) {
        guard state != .recording, state != .transcribing else { return }
        if includingRecordingStart || !starting {
            companion.dismiss()
            hud.dismiss()
        }
        let previous = preparationTask, pendingTranslation = translationPrepare
        let pendingStart = includingRecordingStart && starting ? recordingTask : nil
        previous?.cancel(); pendingTranslation?.cancel(); pendingStart?.cancel()
        translationGeneration &+= 1
        isPreparingTranslation = false
        translationDownload = nil
        preparationGeneration &+= 1
        let generation = preparationGeneration
        if includingRecordingStart {
            if starting { recordingGeneration &+= 1 }
            starting = false; stopAfterStart = false
        }
        isPreparing = true
        sessionWarning = nil
        modelPreparation = .init(stage: .unloading, fraction: nil)
        state = .unloadingModels
        preparationTask = Task { @MainActor in
            await session.unload()
            await previous?.value
            await pendingTranslation?.value
            await pendingStart?.value
            guard preparationGeneration == generation, !Task.isCancelled else { return }
            translationPrepare = nil
            modelPreparation = nil
            preparationTask = nil
            isPreparing = false
            state = .modelsUnloaded
        }
    }

    /// Hotkey press: a running session keeps the trigger it started with even if
    /// Settings change underneath it.
    private func hotkeyDown(submit: Bool) {
        if onboardingGestureHandler?(.rightCommandHeld) == true { return }
        RecordingTriggerPolicy.route(
            .keyDown,
            state: recordingTriggerState,
            begin: { beginRecording(submit: submit) },
            end: endRecording
        )
    }

    /// Captions is always tap-on / tap-off, whatever the hotkey setting says —
    /// holding a key through a talk is not a thing anyone can do.
    private static var togglesOnPress: Bool {
        AppMode.current == .captions || TriggerMode.current == .toggle
    }

    private var recordingTriggerState: RecordingTriggerState {
        RecordingTriggerState(
            isRecording: state == .recording || starting,
            isActive: isActive,
            latchedToggle: latchedToggle,
            isEnabled: DictationEnabled.value
        )
    }

    /// Hotkey release only ends dictation in hold mode (toggle ignores release).
    private func hotkeyUp() {
        if onboardingGestureHandler?(.rightCommandReleased) == true { return }
        RecordingTriggerPolicy.route(
            .keyUp,
            state: recordingTriggerState,
            begin: {},
            end: endRecording
        )
    }

    /// Right ⌘, Return and Escape, from the key tap.
    ///
    /// Not `private`: tests drive the gestures directly, since the tap that
    /// produces them cannot run in a test.
    func handle(_ gesture: KeyGesture) {
        if onboardingGestureHandler?(gesture) == true { return }
        switch gesture {
        case .rightCommandTap:
            guard RightCommandTrigger.isEnabled else { return }
            // This press opened the microphone while it was still down and came
            // up in time to be a tap: keep listening, Return inserts.
            if heldPressStarted { heldPressStarted = false; return }
            // Always tap-on: there is no key left held to release. Stops only
            // what a tap could have started - a held chord still owns its
            // own session.
            RecordingTriggerPolicy.route(
                .keyDown,
                state: recordingTriggerState,
                begin: { beginRecording(submit: false, forceToggle: true, source: .rightCommand) },
                end: endRecording
            )
        case .rightCommandHeld:
            // Only from idle. Held during a take, the key is on its way to
            // stopping it, and its release will.
            guard RightCommandTrigger.isEnabled, DictationEnabled.value, !isActive else { return }
            // Tap-on until the key says otherwise: if it comes up in time to
            // be a tap, this is the tap's dictation, already listening.
            beginRecording(submit: false, forceToggle: true, source: .rightCommand)
            // The hold owns preparation too: a short release keeps that same
            // pending take, and a long release cancels it before the mic opens.
            heldPressStarted = state == .recording || starting
        case .rightCommandReleased:
            guard RightCommandTrigger.isEnabled else { return }
            if heldPressStarted {
                heldPressStarted = false
                endRecording()
            } else {
                // A long press during a take a tap started: letting go
                // finishes it, as a tap would have.
                RecordingTriggerPolicy.route(.keyDown, state: recordingTriggerState,
                                             begin: {}, end: endRecording)
            }
        case .rightCommandChord:
            // ⌘C and friends, typed slowly enough that the microphone had
            // already opened. The shortcut itself went through to the app.
            guard heldPressStarted else { return }
            heldPressStarted = false
            cancelRecording(reason: .shortcut)
        case .confirm:
            // Return before letting go of a held right ⌘ ends that press too.
            heldPressStarted = false
            guard confirmsWithReturn, state == .recording || starting else { return }
            endRecording()
        case .cancel:
            heldPressStarted = false
            guard confirmsWithReturn else { return }
            cancelRecording()
        case .submitWhenDone:
            // `.recording` with a stop pending is the first Return landing
            // while the microphone was still opening: still finishing, as far
            // as the user can tell.
            let finishing = state == .transcribing || (starting && stopAfterStart)
            guard confirmsWithReturn, finishing, !discarding else { return }
            submitRequested = true
            session.skipPostProcessing()
            hud.willSubmit()
        }
    }

    /// The popover's Start/Stop, for anyone without the shortcut to hand.
    /// Always tap-on / tap-off: a click leaves no key to release.
    func toggleFromMenu() {
        if (isManagingModels && state != .unloadingModels) || starting {
            releaseModels()
        } else if state == .recording {
            endRecording()
        } else {
            beginRecording(submit: false, forceToggle: true, source: .menu)
        }
    }

    /// What started a recording, for analytics: whether people actually
    /// reach for right ⌘ is the question the key exists to answer.
    enum TriggerSource: String {
        case shortcut
        case rightCommand = "right_command"
        case menu
    }

    /// Why a take was thrown away: Escape, or a ⌘-shortcut that turned out
    /// to be what a held right ⌘ was for. Kept apart in analytics so
    /// shortcuts do not read as people giving up on dictation.
    enum CancelReason: String {
        case escape
        case shortcut
    }

    /// Not `private`: tests drive this with a substituted session to prove
    /// what it latches.
    func beginRecording(submit: Bool, forceToggle: Bool = false, source: TriggerSource = .shortcut) {
        guard !isActive, !starting else { return }
        guard state != .unloadingModels || onboardingOwnsSession else {
            companion.error(String(localized: "Finishing the previous model operation. Try again in a moment."))
            return
        }
        let language = SpeechLanguage.current
        let modelMode = ModelSetting.current.effective(for: language)
        let captions = AppMode.current == .captions
        let hudStyle: HUDStyle = Accessibility.isTrusted ? .current : .full
        // Preserve the target before loading/waiting UI can change focus.
        let initialCaret = !captions && hudStyle == .caret ? hud.locateCaret(true) : nil
        let toggle = forceToggle || Self.togglesOnPress
        submitOnFinish = captions ? false : submit
        sessionWarning = translationPreparationError.map { "Translation unavailable: \($0)" }
        captureFailed = false
        hasCapturedAudio = false
        starting = true
        stopAfterStart = false
        latchedToggle = toggle
        // Before `state`: its observer reads these to decide what to capture.
        confirmsWithReturn = toggle && !captions
        discarding = false
        cancelReason = .escape
        submitRequested = false
        // Before the new capture replaces the old: a Return held back for the
        // previous paste still has to send it.
        if pasteSettling { closePasteSettle(pasteHasLanded: false) }
        recordingGeneration &+= 1
        pendingDelivery = nil
        modelPreparation = nil
        state = session.isPrepared && !isPreparing && !isPreparingTranslation && !onboardingOwnsSession
            ? .startingRecording : .loadingModels
        companion.preparing(modelPreparationStatus, fraction: modelPreparation?.fraction,
                            onCancel: { [weak self] in self?.releaseModels() })
        let pendingSpeech = preparationTask
        let pendingTranslation = translationPrepare
        let releaseTour = onboardingOwnsSession ? releaseOnboardingSession : nil
        let generation = recordingGeneration
        recordingTask = Task {
            defer { if recordingGeneration == generation { starting = false } }
            do {
                await releaseTour?()
                await pendingSpeech?.value
                await pendingTranslation?.value
                try Task.checkCancellation()
                guard recordingGeneration == generation else { throw CancellationError() }
                // A tour finalizer may restore its borrowed handler. Reconnect
                // only after it has finished, so live text cannot be stolen.
                connectSession()
                state = session.isPrepared ? .startingRecording : .loadingModels
                if let message = translationPreparationError {
                    sessionWarning = "Translation unavailable: \(message)"
                }
                let profile = try WhistleSetting.profile(language: language, mode: modelMode)
                // Translate captions continuously; dictation chooses its output target at Stop.
                let target = captions && TranslationSetting.canTranslate(from: language) ? TranslationSetting.target : nil
                do {
                    try await session.prepare(.init(profile: profile, target: target,
                        postProcessing: !captions && UserDefaults.standard.bool(forKey: "speechPostProcessingEnabled"),
                        postProcessingModelID: UserDefaults.standard.string(forKey: "speechPostProcessingModel"),
                    preloadPostProcessing: ModelLoadingPolicy.current == .atLaunch))
                } catch {
                    try Task.checkCancellation()
                    guard recordingGeneration == generation else { throw CancellationError() }
                    guard target != nil else { throw error }
                    // A translation model failure must not prevent live original captions.
                    let message = Self.translationErrorMessage(error)
                    translationPreparationError = message
                    sessionWarning = "Translation unavailable: \(message)"
                    try await session.prepare(.init(profile: profile,
                        postProcessing: !captions && UserDefaults.standard.bool(forKey: "speechPostProcessingEnabled"),
                        postProcessingModelID: UserDefaults.standard.string(forKey: "speechPostProcessingModel"),
                    preloadPostProcessing: ModelLoadingPolicy.current == .atLaunch))
                }
                try Task.checkCancellation()
                guard recordingGeneration == generation else { throw CancellationError() }
                modelPreparation = nil
                state = .startingRecording
                companion.updatePreparation(String(localized: "Starting microphone…"), fraction: nil)
                try await session.start(microphoneUID: MicrophoneSetting.currentUID,
                                        recordingURL: captions ? nil : diagnosticRecordingURL())
                try Task.checkCancellation()
                guard recordingGeneration == generation else { throw CancellationError() }
                state = .recording
                captionsRunning = captions
                dictationSource = language
                dictationMode = modelMode
                captionSource = captions ? language : nil
                captionTarget = target
                PostHogSDK.shared.capture(captions ? "captions_started" : "dictation_started", properties: [
                    "model_mode": modelMode.rawValue, "language": language,
                    "trigger_mode": TriggerMode.current.rawValue,
                    "trigger_source": source.rawValue,
                    "insert_mode": Self.insertModeAnalyticsValue,
                ])
                if captions {
                    captionsOverlay.begin(target: TranslationSetting.badge(dictating: language),
                                          display: CaptionsDisplay.current)
                } else {
                    hud.begin(lang: SpeechLanguage.badge(for: language),
                              target: TranslationSetting.badge(dictating: language),
                              interactive: toggle, submits: submitOnFinish,
                              confirmsWithReturn: confirmsWithReturn,
                              // Without Accessibility nothing gets typed, and the
                              // live text is the only place the words show up.
                              style: hudStyle, initialCaret: initialCaret,
                              shortcutLabel: activeShortcutLabel(submit: submitOnFinish),
                              onStop: { [weak self] in self?.endRecording() })
                }
                starting = false
                if stopAfterStart { endRecording() }
                else { companion.dismiss() }
            } catch {
                guard recordingGeneration == generation, !Task.isCancelled else { return }
                modelPreparation = nil
                state = .error(error.localizedDescription)
                hud.dismiss()
                companion.error(error.localizedDescription)
                PostHogSDK.shared.capture("dictation_failed", properties: ["error": error.localizedDescription])
            }
        }
    }

    private func diagnosticRecordingURL() -> URL? {
        guard UserDefaults.standard.bool(forKey: DictationSession.recordUtterancesKey) else { return nil }
        let directory = DiagnosticRecordings.directory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("\(DiagnosticRecordings.filePrefix)\(UUID().uuidString).wav")
        } catch {
            dictationLog.error("Diagnostic audio failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            return nil
        }
    }

    /// Events arrive on the main actor so final HUD presentation cannot be
    /// overtaken by a queued update from the previous utterance.
    private func echo(_ confirmed: String, _ partial: String) {
        if captionsRunning {
            captionsOverlay.update(confirmed: confirmed, partial: partial)
        } else {
            hud.update(confirmed: confirmed, partial: partial)
        }
    }

    /// Escape: stop listening and insert nothing. Runs the ordinary stop so the
    /// microphone and the session's lifecycle close the same way, and only
    /// the delivery is skipped.
    func cancelRecording(reason: CancelReason = .escape) {
        guard state == .recording || starting else { return }
        discarding = true
        cancelReason = reason
        endRecording()
    }

    func endRecording() {
        if starting {
            if state == .loadingModels || state == .unloadingModels { releaseModels() }
            else { stopAfterStart = true; syncKeyCapture() }
            return
        }
        guard state == .recording else { return }
        let discard = discarding
        if submitRequested { session.skipPostProcessing() }
        let cancelReasonAtStop = cancelReason
        state = .transcribing
        let captions = captionsRunning
        let displayOnly = captions || captureFailed || discard
        let modelModeAtStop = completedModelMode.rawValue
        let submitAtStop = submitOnFinish
        let requestedTarget = TranslationSetting.target
        let selectedSource = translationSource
        captionTranslateTask?.cancel()
        if captions {
            captionsOverlay.dismiss()
        } else if discard {
            hud.dismiss()
            companion.dismiss()
        } else {
            hud.finalizing()
            companion.finishing(String(localized: "Refining the transcript…"))
        }
        recordingTask = Task {
            defer {
                if !captions { Task.detached(priority: .utility) { DiagnosticRecordings.sweep() } }
            }
            do {
                if discard && session.configuration?.postProcessing == true {
                    await session.cancel()
                    state = .modelsUnloaded
                    syncKeyCapture()
                    return
                }
                // Close the microphone before potentially preparing a newly selected translation.
                let source = try await session.stopSource()
                let target = requestedTarget.flatMap {
                    LanguagePair.route(from: source.sourceLanguage ?? selectedSource, to: $0) == nil ? nil : $0
                }
                var result = source
                if !displayOnly && !captureFailed {
                    do {
                        let previousError = translationPreparationError
                        try await session.setTranslation(target: target, priority: .quality)
                        translationPreparationError = nil
                        if let previousError,
                           sessionWarning == "Translation unavailable: \(previousError)" || sessionWarning == "Translation failed: \(previousError)" {
                            sessionWarning = nil
                        }
                        if target != nil { hud.translating() }
                    } catch {
                        let message = Self.translationErrorMessage(error)
                        translationPreparationError = message
                        sessionWarning = "Translation failed: \(message)"
                    }
                } else if captureFailed {
                    try await session.setTranslation(target: nil, priority: .quality)
                }
                do {
                    result = try await session.finishTranslation()
                } catch {
                    // Always finish the shared lifecycle, even if target preparation failed.
                    // The original remains the atomic delivery fallback.
                    let message = Self.translationErrorMessage(error)
                    translationPreparationError = message
                    sessionWarning = "Translation failed: \(message)"
                }
                let final = result.text
                if discard {
                    PostHogSDK.shared.capture("dictation_cancelled", properties: [
                        "character_count": final.count, "model_mode": modelModeAtStop,
                        "reason": cancelReasonAtStop.rawValue,
                    ])
                } else if displayOnly || captureFailed {
                    if !captions {
                        hud.finish(final, delivery: .displayedOnly)
                    } else if captureFailed {
                        // The band just vanished mid-talk; say why on the speaker's screen.
                        hud.error(sessionWarning ?? "")
                    }
                    PostHogSDK.shared.capture("captions_completed", properties: [
                        "phrase_count": result.transcript.utterances.count, "character_count": final.count,
                    ])
                } else {
                    let translated = Self.completeTranslation(in: result.transcript)
                    let payload = translated.isEmpty ? final : translated
                    // Read now, not at stop: a second Return lands while the
                    // text is still being finalised, which is after the stop.
                    let submit = submitAtStop || submitRequested
                    let delivery = deliverFinal(payload, source: final, translation: translated,
                        quality: !translated.isEmpty && session.configuration?.translationQuality == .quality, submit: submit)
                    PostHogSDK.shared.capture("dictation_completed", properties: [
                        "word_count": final.split(separator: " ").count, "character_count": final.count,
                        "is_empty": final.isEmpty, "model_mode": modelModeAtStop,
                        "insert_mode": Self.insertModeAnalyticsValue, "submit_on_finish": submit,
                        "delivered": delivery == .typed,
                    ])
                }
                captionsRunning = false
                if let warning = sessionWarning, !discard {
                    companion.error(warning)
                } else { companion.dismiss() }
                captionSource = nil
                captionTarget = nil
                state = discard ? .idle : .transcribed(final)
            } catch {
                state = .error(error.localizedDescription)
                hud.dismiss()
                companion.error(error.localizedDescription)
            }
        }
    }

    /// Keep Return held back until the paste has landed - `TextInjector` says
    /// so through `pasteDidSettle` once an app has taken the text - then let
    /// it go, and press Return for the user if they asked to send meanwhile.
    ///
    /// Asked of the tap, not of `submitRequested`: the tap's gesture for a
    /// Return travels to this thread on its own and can still be on its way.
    /// `endCapture` releases the key and reports a held-back Return in one
    /// step, so a press is either counted there or reaches the app after the
    /// text, never eaten.
    ///
    /// Not `private`: tests drive the window directly, since reaching it
    /// through a real paste would write to the developer's clipboard.
    func holdReturnUntilPasteLands(alreadySubmitting: Bool) {
        pasteSettling = true
        settleAlreadySubmits = alreadySubmitting
        syncKeyCapture()
    }

    /// What the injector says about the paste of take `generation`: an app
    /// took the text, or none did. A Return held back for text that never
    /// landed is not sent - it would send the field without it.
    func pasteDidSettle(landed: Bool, generation: Int) {
        if let pending = pendingDelivery, pending.generation == generation,
           recordingGeneration == generation {
            pendingDelivery = nil
            let failure = String(localized: "Could not paste the text. Copy Last Dictation is available in the Murmator menu.")
            hud.finish(pending.text, delivery: landed ? .typed : .failed(failure),
                translation: pending.translation, translationIsQuality: pending.quality)
            if !landed {
                sessionWarning = failure
                companion.error(failure)
            }
            let elapsed = pending.started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            dictationLog.notice("Delivery settled: generation=\(generation) read=\(landed) seconds=\(seconds) characters=\(self.lastOutputText.count)")
        }
        if returnAwaitingPaste == generation {
            returnAwaitingPaste = nil
            if landed { pressReturn() }
            return
        }
        // A newer recording cut the window short and already closed it.
        guard recordingGeneration == generation, pasteSettling else { return }
        closePasteSettle(pasteHasLanded: true, send: landed)
        syncKeyCapture()
    }

    /// End the settle window: release Return, and send a Return held back in
    /// it. A new recording can end the window early - tapping straight into
    /// the next dictation - and then the paste may not have landed yet, so
    /// the Return waits for it on its own (`returnAwaitingPaste`).
    private func closePasteSettle(pasteHasLanded: Bool, send: Bool = true) {
        pasteSettling = false
        guard keyCaptureSink?.endCapture() == true, !settleAlreadySubmits, send else { return }
        if pasteHasLanded {
            pressReturn()
        } else {
            // Still the old take's number: the new one is stamped after this.
            returnAwaitingPaste = recordingGeneration
        }
    }

    /// A failed phrase must never turn one atomic paste into a truncated message.
    static func completeTranslation(in transcript: RecordingTranscript) -> String {
        let content = transcript.utterances.filter { !$0.text.isEmpty }
        guard !content.isEmpty,
              content.allSatisfy({
                  $0.translationFailed != true && $0.translation != nil && ($0.translationFailed == false || !($0.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }) else { return "" }
        return transcript.translatedText
    }

    /// Posting ⌘V is only a request. Keep the HUD until the injector reports
    /// whether anyone took the text, and retain a recovery copy either way.
    @discardableResult
    func deliverFinal(_ payload: String, source: String, translation: String = "", quality: Bool = false, submit: Bool) -> TranscriptDelivery {
        guard !payload.isEmpty else {
            hud.finish(source, delivery: .typed)
            return .typed
        }
        lastOutputText = payload
        pendingDelivery = .init(generation: recordingGeneration, text: source, translation: translation, quality: quality)
        if confirmsWithReturn { holdReturnUntilPasteLands(alreadySubmitting: submit) }
        let delivery = insertFinal(payload, submit: submit)
        if delivery != .typed {
            pendingDelivery = nil
            if pasteSettling { closePasteSettle(pasteHasLanded: true, send: false); syncKeyCapture() }
            hud.finish(source, delivery: delivery, translation: translation, translationIsQuality: quality)
        }
        return delivery
    }

    func copyLastDictation() {
        guard !lastOutputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOutputText, forType: .string)
    }

    /// Paste the final transcript into the focused field. Posting ⌘V needs
    /// Accessibility — if untrusted, prompt once and leave the text on the clipboard
    /// so it's not lost. Secure input (password fields) blocks paste; we say so in
    /// the HUD instead of dropping silently.
    ///
    /// Neither of those two paths can submit: Return is posted only on the branch of
    /// `TextInjector.paste` that actually pressed ⌘V, after it, and only once the text
    /// was read - which is also when a Return held back meanwhile goes
    /// (`pasteDidSettle`). Sending an empty message because the text never landed is
    /// the worst thing this feature could do, so that invariant is structural rather
    /// than a condition someone must remember. (A read can be a clipboard manager's;
    /// see `TextInjector.paste`.)
    private func insertFinal(_ text: String, submit: Bool) -> TranscriptDelivery {
        guard accessibilityTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(TextInjector.payload(text, submit: submit), forType: .string)
            if !promptedAccessibility { promptedAccessibility = true; Accessibility.prompt() }
            return .failed(String(localized: "On the clipboard — grant Accessibility to type"))
        }
        let generation = recordingGeneration
        switch pasteTranscript(text, submit, { [weak self] landed in
            MainActor.assumeIsolated { self?.pasteDidSettle(landed: landed, generation: generation) }
        }) {
        case .pasted:
            return .typed
        case .failed:
            return .failed(String(localized: "Could not type it — press ⌘V"))
        case .copiedSecureInput:
            return .failed(String(localized: "Field is protected — press ⌘V"))
        }
    }
}
