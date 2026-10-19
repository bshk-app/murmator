import Foundation
import MurmurCore
import AIProvidersCore

public actor ProviderTextTranslator: TextTranslationEngine {
    private let provider: any AITranslationProviding
    private let model: String
    public init(provider: any AITranslationProviding, model: String) { self.provider = provider; self.model = model }
    public nonisolated func availableQualities(from: String, to: String) -> [ProcessingQuality] { [.quality] }
    public func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation(); await onProgress(1)
    }
    public func translate(_ text: String, from: String, to: String) async throws -> String {
        let result = try await provider.translate(text, from: from, to: to, model: model)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.invalidResponse }; return result
    }
    public var residentModelCount: Int { 0 }
    public func unload() {}
}
