import Foundation
import MurmurCore
import MurmurSpeech
import MurmurTranslation
import MurmurPostProcessing
import os

@MainActor public protocol RecordingSessioning: AnyObject {
    var onEvent: ((RecordingSession.Event) -> Void)? { get set }
    var configuration: RecordingSession.Configuration? { get }
    var state: RecordingSession.State { get }
    var isPrepared: Bool { get }
    var capturedSeconds: Double { get }
    var transcript: RecordingTranscript { get }
    var residentTranslationModelCount: Int { get async }
    func prepare(_ configuration: RecordingSession.Configuration) async throws
    func prepareTranslation(from: String, to: String, priority: ProcessingQuality,
                            onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws
    func start(microphoneUID: String?, recordingURL: URL?) async throws
    func stopSource() async throws -> RecordingSession.Result
    func skipPostProcessing()
    func finishTranslation() async throws -> RecordingSession.Result
    func stop() async throws -> RecordingSession.Result
    func setTranslation(target: String?, priority: ProcessingQuality) async throws
    func cancel() async
    func unload() async
}

public extension RecordingSessioning {
    func skipPostProcessing() {}
}

/// Shared foreground recording lifecycle. Apps supply paths and display events;
/// this type owns model lifetime, transcript correction and translation ordering.
@MainActor public final class RecordingSession: RecordingSessioning {
    public static func postProcessingStorageLocations() -> [ModelStorageLocation] {
        #if os(iOS)
        let locations = [SpeechLanguageDetector.storageLocation()] + LocalTranscriptEditor.storageLocations()
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        return locations.filter { $0.root.resolvingSymlinksInPath().path.hasPrefix(home) }
        #else
        return []
        #endif
    }
    public struct Configuration {
        public let profile: SpeechRecognitionProfile
        public var target: String?
        public var translationQuality: ProcessingQuality
        public let postProcessing: Bool
        public let postProcessingModelID: String?
        public let preloadPostProcessing: Bool
        public let localProvidersOnly: Bool
        public init(profile: SpeechRecognitionProfile, target: String? = nil, translationQuality: ProcessingQuality = .quality,
                    postProcessing: Bool = false, postProcessingModelID: String? = nil,
                    preloadPostProcessing: Bool = false, localProvidersOnly: Bool = false) {
            self.profile = profile
            self.target = target == profile.language ? nil : target
            self.translationQuality = translationQuality
            self.postProcessing = postProcessing
            self.postProcessingModelID = postProcessingModelID
            self.preloadPostProcessing = preloadPostProcessing
            self.localProvidersOnly = localProvidersOnly
        }
    }
    public enum State: Equatable { case idle, preparing, ready, recording, finishing }
    public struct Preparation {
        public enum Stage { case unloading, speech, translation, warmup, textModel }
        public let stage: Stage
        public let fraction: Double?
        public init(stage: Stage, fraction: Double?) { self.stage = stage; self.fraction = fraction }
    }
    public enum Failure: Error { case recognition(String), translation(String), recording(String), capture(String) }
    public enum FinishingStage: Equatable, Sendable { case recognition, languageDetection, textEditing }
    public enum Event {
        case state(State)
        case preparation(Preparation)
        case finishing(FinishingStage)
        case snapshot(CaptionSnapshot)
        case translation(String, [UtteranceTranslation])
        case capture(Int, Float)
        case speech(SpeechEvent)
        case telemetry(SpeechQualificationSnapshot)
        case failure(Failure)
    }
    public struct Result {
        public let transcript: RecordingTranscript
        public let duration: Double
        public let sourceLanguage: String?
        public let postProcessingModelID: String?
        public let originalTranscript: RecordingTranscript?
        public var text: String { transcript.text }
        public var translation: String { transcript.translatedText }
        public init(transcript: RecordingTranscript, duration: Double, sourceLanguage: String? = nil, postProcessingModelID: String? = nil,
                    originalTranscript: RecordingTranscript? = nil) {
            self.transcript = transcript; self.duration = duration
            self.sourceLanguage = sourceLanguage; self.postProcessingModelID = postProcessingModelID
            self.originalTranscript = originalTranscript
        }
    }
    public enum LifecycleError: Error { case busy, notPrepared, notRecording, sourceNotFinished }

    public var onEvent: ((Event) -> Void)?
    public private(set) var configuration: Configuration?
    public private(set) var state = State.idle
    public private(set) var transcript = RecordingTranscript()
    public private(set) var capturedSeconds = 0.0
    /// Diagnostics for the last file replay; normal microphone sessions do not
    /// depend on these measurements. Compute includes the speech adapter/VAD.
    public private(set) var lastQualificationReplay: SpeechReplayResult?
    public var isPrepared: Bool { configuration != nil && speech != nil && state != .preparing && cleanup == nil }
    public var residentTranslationModelCount: Int { get async { await translator.residentModelCount } }

    private let makeSpeech: (SpeechRecognitionProfile) -> any SessionSpeechDriving
    private let translator: any SessionTranslationDriving
    private let postProcessor: (any SessionPostProcessing)?
    private var recordingURL: URL?
    private var temporaryRecordingURL: URL?
    private var finalLanguage: String?
    private var finalModelID: String?
    private var originalTranscript: RecordingTranscript?
    private var translationNeedsPreparation = false
    private var translationSource: String { finalLanguage ?? configuration?.profile.language ?? "auto" }
    private var speech: (any SessionSpeechDriving)?
    private var speechKey: String?
    private var generation = UUID()
    private var translationGeneration = UUID()
    private var snapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
    private var sourceFinished = false
    private var skippingPostProcessing = false
    private var postProcessingTask: Task<TranscriptPostProcessingResult?, Error>?
    private var captureFailurePending = false
    private var translatedText = ""
    private var translatedSegments: [UtteranceTranslation] = []
    private var inFlight: Task<Void, Error>?
    private var changingTranslation = false
    private var cleanup: Task<Void, Never>?

    public convenience init(modelsRoot: URL, translationRoot: URL, memoryLimit: Int, textEditor: (any TranscriptEditing)? = nil,
                            speechDriver: (any SessionSpeechDriving)? = nil, translationDriver: (any SessionTranslationDriving)? = nil,
                            keepLanguageDetectorWarm: Bool = false) {
        self.init(makeSpeech: { profile in
                      if let speechDriver { return speechDriver }
                      #if os(macOS)
                      if profile.previewBackend == .whistle { return WhistleSessionSpeechDriver() }
                      #endif
                      return SessionSpeechDriver(profile: profile, modelsRoot: modelsRoot, memoryLimit: memoryLimit)
                  },
                  translator: translationDriver ?? SessionTranslationDriver(modelsRoot: translationRoot),
                  postProcessor: SessionPostProcessor(editor: textEditor ?? LocalTranscriptEditor(), keepDetectorWarm: keepLanguageDetectorWarm))
    }
    public static func localSpeechDriver(profile: SpeechRecognitionProfile, modelsRoot: URL, memoryLimit: Int) -> any SessionSpeechDriving {
        #if os(macOS)
        if profile.previewBackend == .whistle { return WhistleSessionSpeechDriver() }
        #endif
        return SessionSpeechDriver(profile: profile, modelsRoot: modelsRoot, memoryLimit: memoryLimit)
    }
    init(makeSpeech: @escaping (SpeechRecognitionProfile) -> any SessionSpeechDriving, translator: any SessionTranslationDriving,
         postProcessor: (any SessionPostProcessing)? = nil) {
        self.makeSpeech = makeSpeech; self.translator = translator; self.postProcessor = postProcessor
    }
    private func changeState(_ value: State) { state = value; onEvent?(.state(value)) }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func available() throws {
        guard inFlight == nil, cleanup == nil else { throw LifecycleError.busy }
    }
    private func perform(_ token: UUID, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let task = Task { try await body() }
        inFlight = task
        defer { if generation == token { inFlight = nil } }
        try await withTaskCancellationHandler(operation: {
            try await task.value
            try check(token)
        }, onCancel: { task.cancel() })
    }

    public func prepare(_ config: Configuration) async throws {
        try available()
        guard state == .idle || state == .ready else { throw LifecycleError.busy }
        let token = generation
        let previous = configuration
        let previousSource = translationSource
        configuration = nil
        changeState(.preparing)
        do {
            try await perform(token) { [self] in
                if config.postProcessing {
                    guard let postProcessor else { throw CocoaError(.featureUnsupported) }
                    onEvent?(.preparation(.init(stage: .speech, fraction: nil)))
                    do {
                        try await postProcessor.prepare { [weak self] value in
                            guard let self, self.generation == token else { return }
                            self.onEvent?(.preparation(value))
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // An optional editor's detector cannot block ordinary
                        // recognition. It retries preparation at editing time.
                        await postProcessor.releaseDetector()
                        Logger(subsystem: "app.bshk.murmur", category: "session-timing").warning("Corrector language preload skipped: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
                    }
                    try check(token)
                    if config.preloadPostProcessing, config.profile.language != "auto" {
                        onEvent?(.preparation(.init(stage: .textModel, fraction: nil)))
                        do {
                            try await postProcessor.prepareEditor(language: config.profile.language, modelID: config.postProcessingModelID)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            // Warm-up is optional; actual editing retries after recognition.
                            Logger(subsystem: "app.bshk.murmur", category: "session-timing").warning("Corrector preload skipped: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
                        }
                        try check(token)
                    }
                } else { await postProcessor?.close() }
                if speechKey != config.profile.configurationID || speech == nil {
                    if let speech {
                        onEvent?(.preparation(.init(stage: .unloading, fraction: nil)))
                        await speech.close()
                    }
                    try check(token)
                    speech = nil; speechKey = nil
                    let driver = makeSpeech(config.profile)
                    speech = driver
                    onEvent?(.preparation(.init(stage: .speech, fraction: nil)))
                    try await driver.prepare { [weak self] value in
                        guard let self, self.generation == token else { return }
                        self.onEvent?(.preparation(value))
                    }
                    try check(token)
                    speechKey = config.profile.configurationID
                }
                await translator.cancel()
                translationGeneration = UUID()
                if let target = config.target {
                    if previous?.target != target || previousSource != config.profile.language || previous?.translationQuality != config.translationQuality {
                        try await prepareTranslationImpl(from: config.profile.language, to: target, priority: config.translationQuality, token: token)
                    }
                }
                try check(token)
                configuration = config
                finalLanguage = nil; finalModelID = nil; originalTranscript = nil; translationNeedsPreparation = false
                changeState(.ready)
            }
        } catch {
            if generation == token {
                configuration = nil
                if let speech, speechKey == nil {
                    // Keep cleanup owned: a replacement cannot start while the
                    // failed driver's model release is still suspended.
                    onEvent?(.preparation(.init(stage: .unloading, fraction: nil)))
                    try? await perform(token) { await speech.close() }
                    guard generation == token else { throw error }
                    self.speech = nil
                }
                try? await perform(token) { [postProcessor] in await postProcessor?.close() }
                guard generation == token else { throw error }
                changeState(.idle)
            }
            throw error
        }
    }

    public func prepareTranslation(from: String, to: String, priority: ProcessingQuality = .quality,
        onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void = { _ in }) async throws {
        try available()
        guard state == .idle || state == .ready else { throw LifecycleError.busy }
        let token = generation
        configuration = nil
        changeState(.preparing)
        do {
            try await perform(token) { [self] in
                try await prepareTranslationImpl(from: from, to: to, priority: priority, token: token, onProgress: onProgress)
                try check(token)
                changeState(.idle)
            }
        } catch { if generation == token { changeState(.idle) }; throw error }
    }
    private func prepareTranslationImpl(from: String, to: String, priority: ProcessingQuality, token: UUID,
        onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void = { _ in }) async throws {
        onEvent?(.preparation(.init(stage: .translation, fraction: nil)))
        try await translator.prepare(from: from, to: to, priority: priority) { [weak self] progress in
            guard let self, self.generation == token else { return }
            onProgress(progress)
            self.onEvent?(.preparation(.init(stage: .translation, fraction: progress.fraction)))
        }
        try check(token)
        onEvent?(.preparation(.init(stage: .warmup, fraction: nil)))
        try await translator.warmUp(from: from, to: to)
        try check(token)
    }

    public func start(microphoneUID: String?, recordingURL: URL? = nil) async throws {
        try available()
        guard state == .ready, configuration != nil, let speech else { throw LifecycleError.notPrepared }
        generation = UUID(); translationGeneration = UUID()
        let token = generation
        transcript = RecordingTranscript(); sourceFinished = false; skippingPostProcessing = false; captureFailurePending = false; capturedSeconds = 0
        finalLanguage = nil; finalModelID = nil; originalTranscript = nil
        removeTemporaryRecording()
        if configuration?.postProcessing == true && recordingURL == nil {
            temporaryRecordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-postprocess-\(UUID().uuidString).wav")
        }
        self.recordingURL = recordingURL ?? temporaryRecordingURL
        snapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
        translatedText = ""; translatedSegments = []
        wire(speech, token: token)
        changeState(.recording)
        do {
            try await perform(token) { [self] in
                await translator.cancel()
                try check(token)
                try await speech.start(microphoneUID: microphoneUID, recordingURL: self.recordingURL)
            }
        } catch {
            if generation == token { await unload() }
            throw error
        }
    }

    /// Fixed-rate file input for device qualification, through the same transcript
    /// and translation orchestration as capture. Never opens a microphone.
    public func replayRealtimeForQualification(_ samples: [Float]) async throws -> Result {
        try available()
        guard state == .ready, configuration != nil, let speech else { throw LifecycleError.notPrepared }
        lastQualificationReplay = nil
        generation = UUID(); translationGeneration = UUID()
        let token = generation
        transcript = RecordingTranscript(); sourceFinished = false; skippingPostProcessing = false; captureFailurePending = false; capturedSeconds = 0
        snapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
        translatedText = ""; translatedSegments = []
        wire(speech, token: token)
        changeState(.recording)
        do {
            try await perform(token) { [self] in
                await translator.cancel()
                try check(token)
                let replay = try await speech.replay(samples)
                try check(token)
                lastQualificationReplay = replay
                let finalSnapshot = await speech.snapshot()
                try check(token)
                accept(finalSnapshot, token: token)
                capturedSeconds = replay.audioSeconds
                transcript.finish(fallback: replay.text, endSample: Int(replay.audioSeconds * 16_000))
                sourceFinished = true
                translationGeneration = UUID()
                changeState(.finishing)
            }
            return try await finishTranslation()
        } catch {
            if generation == token { await unload() }
            throw error
        }
    }

    private func wire(_ driver: any SessionSpeechDriving, token: UUID) {
        driver.onSnapshot = { [weak self] value in self?.accept(value, token: token) }
        driver.onCapture = { [weak self] frames, peak in
            guard let self, self.generation == token, self.state == .recording else { return }
            self.capturedSeconds += Double(frames) / 16_000
            self.onEvent?(.capture(frames, peak))
        }
        driver.onError = { [weak self] message in self?.emit(.failure(.recognition(message)), token: token) }
        driver.onRecordingError = { [weak self] message in self?.emit(.failure(.recording(message)), token: token) }
        driver.onCaptureError = { [weak self] message in self?.captureFailed(message, token: token) }
        driver.onSpeech = { [weak self] value in self?.emit(.speech(value), token: token) }
        driver.onTelemetry = { [weak self] value in self?.emit(.telemetry(value), token: token) }
    }
    private func captureFailed(_ message: String, token: UUID) {
        guard generation == token, !captureFailurePending,
              state == .recording || state == .finishing else { return }
        captureFailurePending = true
        let pending = inFlight
        Task { [weak self] in
            _ = try? await pending?.value
            guard let self, self.generation == token else { return }
            while self.inFlight != nil {
                await Task.yield()
                guard self.generation == token else { return }
            }
            // Finalize accepted audio before a consumer's recovery handler unloads
            // models. Otherwise an overload notification would discard the queue.
            if self.state == .recording { _ = try? await self.stopSource() }
            self.emit(.failure(.capture(message)), token: token)
        }
    }
    private func emit(_ event: Event, token: UUID) {
        guard generation == token, state == .recording || state == .finishing else { return }
        onEvent?(event)
    }
    private func accept(_ value: CaptionSnapshot, token: UUID) {
        guard generation == token, !sourceFinished, state == .recording || state == .finishing,
              transcript.apply(value) else { return }
        snapshot = value
        onEvent?(.snapshot(value))
        if state == .recording { updateTranslation(token: token) }
    }
    private func updateTranslation(token: UUID) {
        guard let config = configuration, let target = config.target else { return }
        let revision = translationGeneration
        let value = snapshot
        Task { [weak self, translator] in
            guard let self, self.generation == token, self.translationGeneration == revision, self.state == .recording else { return }
            await translator.update(value, from: config.profile.language, to: target,
                onUpdate: { [weak self] text in Task { @MainActor in
                    guard let self, self.translationIsCurrent(token, revision), self.snapshot.revision == value.revision else { return }
                    self.translatedText = text
                    self.onEvent?(.translation(text, self.translatedSegments))
                } },
                onFailure: { [weak self] message in Task { @MainActor in
                    guard let self, self.translationIsCurrent(token, revision), self.snapshot.revision == value.revision else { return }
                    self.onEvent?(.failure(.translation(message)))
                } },
                onSegments: { [weak self] segments in Task { @MainActor in
                    guard let self, self.translationIsCurrent(token, revision), self.snapshot.revision == value.revision else { return }
                    self.translatedSegments = segments
                    self.transcript.applyTranslations(segments)
                    self.onEvent?(.translation(self.translatedText, segments))
                } })
        }
    }
    private func translationIsCurrent(_ token: UUID, _ revision: UUID) -> Bool {
        generation == token && translationGeneration == revision && state == .recording
    }

    public func setTranslation(target: String?, priority: ProcessingQuality = .quality) async throws {
        let entryGeneration = generation
        if changingTranslation, let pending = inFlight {
            pending.cancel()
            _ = try? await pending.value
            // The previous caller clears inFlight in its defer after this same
            // task completes; yield through the actor before taking ownership.
            while changingTranslation { await Task.yield(); try check(entryGeneration) }
        }
        try check(entryGeneration)
        try available()
        guard var config = configuration, state == .recording || state == .ready || (state == .finishing && sourceFinished) else { throw LifecycleError.notPrepared }
        let source = translationSource
        let target = target == source ? nil : target
        guard target != config.target || priority != config.translationQuality else { return }
        let token = generation
        translationGeneration = UUID()
        config.target = nil
        configuration = config
        clearTranslations()
        changingTranslation = true
        defer { if generation == token { changingTranslation = false } }
        do {
            try await perform(token) { [self] in
                await translator.cancel()
                if let target {
                    try await prepareTranslationImpl(from: source, to: target, priority: priority, token: token)
                }
                try check(token)
                config.target = target; config.translationQuality = priority
                configuration = config
                translationNeedsPreparation = false
                if state == .recording { updateTranslation(token: token) }
            }
        } catch { throw error }
    }
    private func clearTranslations() {
        transcript.clearTranslations()
        translatedText = ""; translatedSegments = []
        onEvent?(.translation("", []))
    }

    /// Finalize and publish source before translation: consumers can durably save
    /// the original even when the quality model fails or finishing is cancelled.
    public func stopSource() async throws -> Result {
        let entryGeneration = generation
        if changingTranslation, let pending = inFlight {
            pending.cancel()
            _ = try? await pending.value
            while changingTranslation { await Task.yield(); try check(entryGeneration) }
        }
        try check(entryGeneration)
        try available()
        if state == .finishing && sourceFinished { return result }
        guard state == .recording, let speech else { throw LifecycleError.notRecording }
        let token = generation
        let stopStarted = Date()
        let timingLog = Logger(subsystem: "app.bshk.murmur", category: "session-timing")
        timingLog.notice("Stop requested")
        translationGeneration = UUID()
        changeState(.finishing)
        onEvent?(.finishing(.recognition))
        do { try await perform(token) { [self] in
            let text = try await speech.stop()
            try check(token)
            let finalSnapshot = await speech.snapshot()
            try check(token)
            accept(finalSnapshot, token: token)
            capturedSeconds = speech.capturedSeconds
            transcript.finish(fallback: text, endSample: Int(capturedSeconds * 16_000))
            sourceFinished = true
            timingLog.notice("Recognition finished: seconds=\(Date().timeIntervalSince(stopStarted)) characters=\(self.transcript.text.count)")
            if !skippingPostProcessing, configuration?.postProcessing == true, let postProcessor, let recordingURL {
                let detectionStarted = Date()
                onEvent?(.finishing(.languageDetection))
                // Demand loading releases live weights before editing. A host
                // choosing preload keeps the prepared recognizer and editor ready.
                if configuration?.preloadPostProcessing != true {
                    await speech.close()
                    try check(token)
                    self.speech = nil; speechKey = nil
                }
                await translator.unload()
                try check(token)
                translationNeedsPreparation = true
                do {
                    let processing = Task { [self] in try await postProcessor.process(url: recordingURL, transcript: transcript,
                        modelID: configuration?.postProcessingModelID) { [weak self] language in
                            guard let self, self.generation == token, !self.skippingPostProcessing else { return }
                            self.finalLanguage = language
                            timingLog.notice("Language ready: seconds=\(Date().timeIntervalSince(detectionStarted))")
                            self.onEvent?(.finishing(.textEditing))
                        } }
                    postProcessingTask = processing
                    if skippingPostProcessing { processing.cancel() }
                    defer { postProcessingTask = nil }
                    let processed = try await withTaskCancellationHandler {
                        try await processing.value
                    } onCancel: { processing.cancel() }
                    try check(token)
                    if let processed, !skippingPostProcessing {
                        finalLanguage = processed.language; finalModelID = processed.modelID
                        if processed.transcript.text != transcript.text {
                            var original = transcript; original.clearTranslations()
                            originalTranscript = original
                        }
                        transcript = processed.transcript
                        clearTranslations()
                        onEvent?(.snapshot(.init(revision: snapshot.revision &+ 1,
                            confirmed: transcript.utterances.map {
                                .init(id: $0.id, startSample: $0.startSample, endSample: $0.endSample, text: $0.text, state: .confirmed)
                            }, provisional: "", settledThroughSample: Int(capturedSeconds * 16_000))))
                    }
                } catch {
                    try check(token)
                    // Optional refinement cannot erase the finished original.
                    if !skippingPostProcessing {
                        onEvent?(.failure(.recognition("Post-processing failed: \(error.localizedDescription)")))
                    }
                }
                if configuration?.preloadPostProcessing == true { await postProcessor.releaseDetector() }
                else { await postProcessor.close() }
                try check(token)
            }
            removeTemporaryRecording()
            timingLog.notice("Source finished: seconds=\(Date().timeIntervalSince(stopStarted)) characters=\(self.transcript.text.count)")
        } } catch {
            if generation == token {
                // Never promote a preview or return a deliverable result when
                // a recognizer failed its final. Release it so Retry can prepare.
                accept(.init(revision: snapshot.revision &+ 1, confirmed: snapshot.confirmed,
                             provisional: "", settledThroughSample: snapshot.settledThroughSample), token: token)
                await unload()
            }
            throw error
        }
        return result
    }
    /// Skip optional editing, keeping the recognized source and take ownership.
    public func skipPostProcessing() {
        guard state == .recording || state == .finishing else { return }
        skippingPostProcessing = true
        postProcessingTask?.cancel()
    }
    public func finishTranslation() async throws -> Result {
        try available()
        guard state == .finishing, sourceFinished, let config = configuration else { throw LifecycleError.sourceNotFinished }
        let token = generation
        do {
            try await perform(token) { [self] in
                if let target = config.target, !transcript.text.isEmpty {
                    let source = translationSource
                    if source == target { await translator.cancel(); changeState(.ready); return }
                    if translationNeedsPreparation {
                        try await prepareTranslationImpl(from: source, to: target, priority: config.translationQuality, token: token)
                        translationNeedsPreparation = false
                    }
                    try await translator.finish(transcript.utterances, from: source, to: target) { [weak self] value in
                        await self?.acceptFinalTranslation(value, token: token)
                    }
                } else { await translator.cancel() }
                try check(token)
                changeState(.ready)
            }
        } catch {
            if generation == token {
                changeState(.ready)
                if !(error is CancellationError) { onEvent?(.failure(.translation(error.localizedDescription))) }
            }
            throw error
        }
        return result
    }
    private func acceptFinalTranslation(_ value: UtteranceTranslation, token: UUID) {
        guard generation == token, state == .finishing else { return }
        transcript.applyTranslations([value])
        onEvent?(.translation(transcript.translatedText, [value]))
    }
    public func stop() async throws -> Result {
        _ = try await stopSource()
        return try await finishTranslation()
    }
    private var result: Result {
        .init(transcript: transcript, duration: capturedSeconds, sourceLanguage: translationSource,
              postProcessingModelID: finalModelID, originalTranscript: originalTranscript)
    }

    private func removeTemporaryRecording() {
        if let temporaryRecordingURL { try? FileManager.default.removeItem(at: temporaryRecordingURL) }
        temporaryRecordingURL = nil; recordingURL = nil
    }

    public func cancel() async { await unload() }
    public func unload() async {
        if let cleanup { await cleanup.value; return }
        generation = UUID(); translationGeneration = UUID()
        configuration = nil; speechKey = nil
        changeState(.preparing)
        onEvent?(.preparation(.init(stage: .unloading, fraction: nil)))
        let pending = inFlight
        pending?.cancel()
        let driver = speech
        let task = Task { [translator, postProcessor] in
            _ = try? await pending?.value
            if let driver { await driver.close() }
            await postProcessor?.close()
            await translator.unload()
        }
        cleanup = task
        await task.value
        speech = nil; inFlight = nil; changingTranslation = false; cleanup = nil
        removeTemporaryRecording()
        changeState(.idle)
    }
}
