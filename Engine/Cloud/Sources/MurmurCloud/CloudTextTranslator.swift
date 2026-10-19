import DictatorCore
import Foundation
import MurmurCore

public actor CloudTextTranslator: TextTranslationEngine {
    private let client: DictatorClient
    private var limit = 2000
    public init(client: DictatorClient) {
        self.client = client
    }

    public nonisolated func availableQualities(from _: String, to _: String) -> [ProcessingQuality] {
        [.quality]
    }

    public func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let capabilities = try await client.capabilities()
        guard CloudPolicy.translationTargets(capabilities, source: from).contains(to) else { throw CloudProcessingError.unavailableTranslation }
        limit = capabilities.translation.maxInputChars
        await onProgress(1)
    }

    public func translate(_ text: String, from: String, to: String) async throws -> String {
        guard text.unicodeScalars.count <= limit else { throw CloudProcessingError.inputTooLong(limit) }
        do { return try await client.translate(text: text, from: from, to: to).translation }
        catch { throw NSError(domain: "MurmurCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: CloudPolicy.message(error)]) }
    }

    public var residentModelCount: Int {
        0
    }

    public func unload() {}
}
