import Foundation
import AIProvidersCore
import MurmurCore
import MurmurSpeech
import MurmurSession
import MurmurTranslation

/// All backends share RecordingSession's cancellation, Whisper language detection,
/// whole-text correction and final translation ordering.
@MainActor public final class ProviderRecordingSession: RecordingSessioning {
    public var onEvent: ((RecordingSession.Event) -> Void)?
    public var configuration: RecordingSession.Configuration? { inner?.configuration }
    public var state: RecordingSession.State { inner?.state ?? .idle }
    public var isPrepared: Bool { inner?.isPrepared == true }
    public var capturedSeconds: Double { inner?.capturedSeconds ?? 0 }
    public var transcript: RecordingTranscript { inner?.transcript ?? .init() }
    public var residentTranslationModelCount: Int { get async { await inner?.residentTranslationModelCount ?? 0 } }
    private var inner: RecordingSession?
    private var key: String?
    private let modelsRoot: URL, translationRoot: URL
    private let memoryLimit: Int
    private let preferences: ProviderPreferences
    public private(set) var residentSpeechModelName: String?
    public private(set) var recordingModelDescription = ""
    public init(modelsRoot: URL, translationRoot: URL, memoryLimit: Int, preferences: ProviderPreferences? = nil) {
        self.modelsRoot = modelsRoot; self.translationRoot = translationRoot; self.memoryLimit = memoryLimit; self.preferences = preferences ?? .shared
    }
    private func session(_ profile: SpeechRecognitionProfile, localOnly: Bool) async throws -> RecordingSession {
        let signature = (localOnly ? "{}" : preferences.configurationID) + profile.configurationID
        if key == signature, let inner { return inner }
        guard inner?.state != .recording, inner?.state != .finishing, inner?.state != .preparing else { throw RecordingSession.LifecycleError.busy }
        await inner?.unload(); inner = nil; key = nil
        var editor: (any TranscriptEditing)?
        if !localOnly, let selected = preferences.selection(.textEditing) {
            let connection = try preferences.connection(selected)
            editor = ProviderTranscriptEditor(provider: try preferences.textProvider(connection), model: selected.modelID, options: selected.options ?? .init(), providerID: connection.provider, authentication: connection.auth.rawValue)
        }
        var speech: (any SessionSpeechDriving)?
        let live = localOnly ? nil : preferences.selection(.streamingTranscription)
        let accurate = localOnly ? nil : preferences.selection(.transcription)
        let selected = profile.mode == .accurate ? accurate : live
        let previewName = profile.previewBackend == .whistle ? "Whistle" : "Nemotron"
        func name(_ selection: AISelection?, local: String) throws -> String {
            guard let selection else { return local }
            return "\(try preferences.connection(selection).provider):\(selection.modelID)"
        }
        let stages: [String]
        switch profile.mode {
        case .fast: stages = [try name(live, local: previewName)]
        case .accurate: stages = [try name(accurate, local: profile.model.title)]
        case .hybrid: stages = [try name(live, local: previewName), try name(accurate, local: profile.model.title)]
        }
        recordingModelDescription = "\(profile.mode.rawValue) · " + stages.joined(separator: " + ")
        residentSpeechModelName = selected != nil ? (profile.mode == .hybrid && accurate == nil ? profile.model.title : nil) : profile.mode == .fast ? previewName : profile.mode == .accurate ? profile.model.title : accurate != nil ? previewName : "\(previewName) + \(profile.model.title)"
        if let selected {
            let provider = try preferences.speechProvider(selected)
            let refinement: (any AISpeechProviding)?
            let refinementModel: String?
            if profile.mode == .hybrid {
                refinement = try accurate.map { try preferences.speechProvider($0) } ?? LocalSpeechFileProvider(choice: profile.model, modelsRoot: modelsRoot)
                refinementModel = accurate?.modelID ?? profile.model.rawValue
            } else { refinement = nil; refinementModel = nil }
            speech = ProviderSpeechDriver(provider: provider, request: .init(model: selected.modelID, language: profile.language), mode: profile.mode,
                refinement: refinement, refinementRequest: refinementModel.map { .init(model: $0, language: profile.language) })
        } else if let accurate, profile.mode == .hybrid {
            let preview = try SpeechRecognitionProfile.resolve(language: profile.language, mode: .fast, explicitChoice: profile.model)
            speech = LocalCloudRefiningDriver(base: RecordingSession.localSpeechDriver(profile: preview, modelsRoot: modelsRoot, memoryLimit: memoryLimit),
                provider: try preferences.speechProvider(accurate), request: .init(model: accurate.modelID, language: profile.language))
        }
        var translator: (any SessionTranslationDriving)?
        if !localOnly, let selected = preferences.selection(.translation) {
            translator = ProviderTranslationDriver(provider: try preferences.translationProvider(selected), model: selected.modelID)
        }
        let session = RecordingSession(modelsRoot: modelsRoot, translationRoot: translationRoot, memoryLimit: memoryLimit,
            textEditor: editor, speechDriver: speech, translationDriver: translator, keepLanguageDetectorWarm: editor != nil)
        session.onEvent = { [weak self] event in self?.onEvent?(event) }
        inner = session; key = signature; return session
    }
    public func prepare(_ configuration: RecordingSession.Configuration) async throws { try await session(configuration.profile, localOnly: configuration.localProvidersOnly).prepare(configuration) }
    public func prepareTranslation(from: String, to: String, priority: ProcessingQuality, onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws {
        guard let inner else { throw RecordingSession.LifecycleError.notPrepared }; try await inner.prepareTranslation(from: from, to: to, priority: priority, onProgress: onProgress)
    }
    public func start(microphoneUID: String?, recordingURL: URL?) async throws { guard let inner else { throw RecordingSession.LifecycleError.notPrepared }; try await inner.start(microphoneUID: microphoneUID, recordingURL: recordingURL) }
    public func stopSource() async throws -> RecordingSession.Result { guard let inner else { throw RecordingSession.LifecycleError.notPrepared }; return try await inner.stopSource() }
    public func skipPostProcessing() { inner?.skipPostProcessing() }
    public func finishTranslation() async throws -> RecordingSession.Result { guard let inner else { throw RecordingSession.LifecycleError.notPrepared }; return try await inner.finishTranslation() }
    public func stop() async throws -> RecordingSession.Result { guard let inner else { throw RecordingSession.LifecycleError.notPrepared }; return try await inner.stop() }
    public func setTranslation(target: String?, priority: ProcessingQuality) async throws { guard let inner else { return }; try await inner.setTranslation(target: target, priority: priority) }
    public func cancel() async { await inner?.cancel() }
    public func unload() async { await inner?.unload(); inner = nil; key = nil }
}
