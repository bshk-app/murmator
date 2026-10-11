import Foundation
import MurmurCore
import MurmurSpeech
import MurmurTranslation

// Internal seams keep lifecycle and cancellation tests independent of model files,
// microphone permissions and native inference. Apps use RecordingSessioning.
@MainActor protocol SessionSpeechDriving: AnyObject {
    var onSnapshot: ((CaptionSnapshot) -> Void)? { get set }
    var onCapture: ((Int, Float) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onRecordingError: ((String) -> Void)? { get set }
    var onCaptureError: ((String) -> Void)? { get set }
    var onSpeech: ((SpeechEvent) -> Void)? { get set }
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)? { get set }
    var capturedSeconds: Double { get }
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws
    func start(microphoneUID: String?, recordingURL: URL?) async throws
    func stop() async throws -> String
    func replay(_ samples: [Float]) async throws -> SpeechReplayResult
    func snapshot() async -> CaptionSnapshot
    func close() async
}

extension SessionSpeechDriving {
    func replay(_ samples: [Float]) async throws -> SpeechReplayResult { throw CocoaError(.featureUnsupported) }
}

@MainActor protocol SessionTranslationDriving: AnyObject {
    var residentModelCount: Int { get async }
    func prepare(from: String, to: String, priority: ProcessingQuality,
                 progress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws
    func warmUp(from: String, to: String) async throws
    func update(_ snapshot: CaptionSnapshot, from: String, to: String,
                onUpdate: @escaping @Sendable (String) -> Void,
                onFailure: @escaping @Sendable (String) -> Void,
                onSegments: @escaping @Sendable ([UtteranceTranslation]) -> Void) async
    func finish(_ utterances: [RecordedUtterance], from: String, to: String,
                onSegment: @escaping @Sendable (UtteranceTranslation) async -> Void) async throws
    func cancel() async
    func unload() async
}

@MainActor final class SessionSpeechDriver: SessionSpeechDriving {
    var onSnapshot: ((CaptionSnapshot) -> Void)?
    var onCapture: ((Int, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    private let session: SpeechSession
    private let profile: SpeechRecognitionProfile
    private var replaySeconds: Double?
    var capturedSeconds: Double { replaySeconds ?? session.capturedSeconds }

    init(profile: SpeechRecognitionProfile, modelsRoot: URL, memoryLimit: Int) {
        self.profile = profile
        session = SpeechSession(profile: profile, memoryLimit: memoryLimit, modelsRoot: modelsRoot)
    }
    private func installCallbacks() {
        // Capture the handlers for this run before hopping actors. Reading mutable
        // handlers inside the Task would deliver an old run's event to a new run.
        let snapshot = onSnapshot, capture = onCapture, error = onError
        let recordingError = onRecordingError, captureError = onCaptureError, speech = onSpeech, telemetry = onTelemetry
        session.onSnapshot = { value, _, _, _ in Task { @MainActor in snapshot?(value) } }
        session.onCapture = { count, _, peak, _ in Task { @MainActor in capture?(count, peak) } }
        session.onError = { message in Task { @MainActor in error?(message) } }
        session.onRecordingError = { message in Task { @MainActor in recordingError?(message) } }
        session.onCaptureError = { message in Task { @MainActor in captureError?(message) } }
        session.onModelEvent = { event in Task { @MainActor in speech?(event) } }
        session.onQualificationTelemetry = { value in Task { @MainActor in telemetry?(value) } }
    }
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws {
        let modes: [DictationMode] = profile.mode == .hybrid ? [.accurate, .fast] : [profile.mode]
        for mode in modes {
            progress(.init(stage: .speech, fraction: nil))
            try await session.load(mode: mode, onPreparation: { _ in }) { value in
                progress(.init(stage: .speech, fraction: value.totalUnitCount > 0 ? value.fractionCompleted : nil))
            }
            try Task.checkCancellation()
        }
        progress(.init(stage: .warmup, fraction: nil))
        try await session.warmUp(mode: profile.mode, language: profile.language)
    }
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
        replaySeconds = nil
        installCallbacks()
        try await session.start(mode: profile.mode, language: profile.language, microphoneUID: microphoneUID, recordingURL: recordingURL)
    }
    func replay(_ samples: [Float]) async throws -> SpeechReplayResult {
        installCallbacks()
        let result = try await session.replayRealtimeForQualification(samples, mode: profile.mode, language: profile.language)
        replaySeconds = result.audioSeconds
        return result
    }
    func stop() async -> String { await session.stop() }
    func snapshot() async -> CaptionSnapshot { await session.snapshot() }
    func close() async { await session.close() }
}

@MainActor final class SessionTranslationDriver: SessionTranslationDriving {
    private let session: TranslationSession
    init(modelsRoot: URL) { session = TranslationSession(modelsRoot: modelsRoot) }
    var residentModelCount: Int { get async { await session.residentModelCount } }
    func prepare(from: String, to: String, priority: ProcessingQuality,
                 progress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws {
        try await session.prepare(from: from, to: to, priority: priority, onProgress: progress)
    }
    func warmUp(from: String, to: String) async throws { try await session.warmUp(from: from, to: to) }
    func update(_ snapshot: CaptionSnapshot, from: String, to: String,
                onUpdate: @escaping @Sendable (String) -> Void,
                onFailure: @escaping @Sendable (String) -> Void,
                onSegments: @escaping @Sendable ([UtteranceTranslation]) -> Void) async {
        await session.update(snapshot, from: from, to: to, onUpdate: onUpdate, onFailure: onFailure, onSegments: onSegments)
    }
    func finish(_ utterances: [RecordedUtterance], from: String, to: String,
                onSegment: @escaping @Sendable (UtteranceTranslation) async -> Void) async throws {
        try await session.finishUtterances(utterances, from: from, to: to, onSegment: onSegment)
    }
    func cancel() async { await session.cancel() }
    func unload() async { await session.unload() }
}
