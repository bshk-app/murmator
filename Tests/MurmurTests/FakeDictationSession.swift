import Foundation
@testable import MurmurKit

/// App adapter tests exercise the shared asynchronous boundary without models or a microphone.
@MainActor
final class FakeDictationSession: RecordingSessioning {
    var onEvent: ((RecordingSession.Event) -> Void)?
    var configuration: RecordingSession.Configuration?
    var ready = true
    var isPrepared: Bool { ready }
    var state: RecordingSession.State = .ready
    var capturedSeconds: Double = 0
    var residentTranslationModelCount: Int { get async { 0 } }
    var transcript = RecordingTranscript()
    var startError: Error?
    var translationError: Error?
    var startGate: (() async -> Void)?
    var prepareGate: (() async -> Void)?
    var unloadGate: (() async -> Void)?
    private(set) var prepareCount = 0
    private(set) var unloadCount = 0
    private(set) var startedMode: DictationMode?
    private(set) var startedLanguage: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var finishCount = 0
    private(set) var targets: [String?] = []

    func prepare(_ configuration: RecordingSession.Configuration) async throws {
        prepareCount += 1
        state = .preparing
        onEvent?(.preparation(.init(stage: .speech, fraction: nil)))
        await prepareGate?()
        try Task.checkCancellation()
        self.configuration = configuration
        ready = true
        state = .ready
    }
    func prepareTranslation(from: String, to: String, priority: ProcessingQuality,
                            onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws {}
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
        await startGate?()
        if let startError { throw startError }
        startedMode = configuration?.profile.mode
        startedLanguage = configuration?.profile.language
        startCount += 1
        state = .recording
    }
    func stopSource() async throws -> RecordingSession.Result {
        stopCount += 1
        state = .finishing
        return .init(transcript: transcript, duration: capturedSeconds)
    }
    func finishTranslation() async throws -> RecordingSession.Result {
        finishCount += 1
        state = .ready
        return .init(transcript: transcript, duration: capturedSeconds)
    }
    func stop() async throws -> RecordingSession.Result { _ = try await stopSource(); return try await finishTranslation() }
    func setTranslation(target: String?, priority: ProcessingQuality) async throws {
        if let translationError { throw translationError }
        targets.append(target)
    }
    func cancel() async { await unload() }
    func unload() async {
        unloadCount += 1
        ready = false
        await unloadGate?()
        configuration = nil
        state = .idle
    }
}
