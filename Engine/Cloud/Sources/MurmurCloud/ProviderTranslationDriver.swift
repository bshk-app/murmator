import Foundation
import MurmurCore
import MurmurSession
import MurmurTranslation
import AIProvidersCore

@MainActor final class ProviderTranslationDriver: SessionTranslationDriving {
    private let provider: any AITranslationProviding
    private let model: String
    init(provider: any AITranslationProviding, model: String) { self.provider = provider; self.model = model }
    var residentModelCount: Int { get async { 0 } }
    func prepare(from: String, to: String, priority: ProcessingQuality, progress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void) async throws { try Task.checkCancellation() }
    func warmUp(from: String, to: String) async throws {}
    // Network translation is performed once after final text editing. Never send
    // every provisional revision as a separate billable request.
    func update(_ snapshot: CaptionSnapshot, from: String, to: String, onUpdate: @escaping @Sendable (String) -> Void,
                onFailure: @escaping @Sendable (String) -> Void, onSegments: @escaping @Sendable ([UtteranceTranslation]) -> Void) async {}
    func finish(_ utterances: [RecordedUtterance], from: String, to: String, onSegment: @escaping @Sendable (UtteranceTranslation) async -> Void) async throws {
        // Preserve sentence context, then project the translation to coarse spans.
        let source = utterances.filter { !$0.text.isEmpty }
        guard !source.isEmpty else { return }
        let text = try await provider.translate(source.map(\.text).joined(separator: " "), from: from, to: to, model: model)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.invalidResponse }
        try Task.checkCancellation()
        // Translation has no word alignment. Keep the whole output on the first
        // span, mark remaining spans complete without fabricating timings.
        for (index, utterance) in source.enumerated() {
            await onSegment(.init(id: utterance.id, source: utterance.text, text: index == 0 ? text : "", isFinal: true, failed: false))
        }
    }
    func cancel() async {}
    func unload() async {}
}
