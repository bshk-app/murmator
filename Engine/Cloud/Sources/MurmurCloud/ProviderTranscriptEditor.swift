import Foundation
import MurmurCore
import AIProvidersCore
import os

/// Selection is pinned to this recording; changing settings affects the next take.
public actor ProviderTranscriptEditor: TranscriptEditing {
    private let provider: any AITextProviding
    private let model: String
    private let options: AITextOptions
    private let timeout: Duration
    private let providerID: String
    private let authentication: String
    private let logger = Logger(subsystem: "app.bshk.murmur", category: "cloud-corrector")
    public init(provider: any AITextProviding, model: String, options: AITextOptions = .init(), timeout: Duration = .seconds(30), providerID: String = "custom", authentication: String = "custom") {
        self.provider = provider; self.model = model; self.timeout = timeout
        self.options = options
        self.providerID = providerID; self.authentication = authentication
    }
    public func prepare(language: String, modelID: String?) async throws {}
    public func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        let started = Date()
        let requestID = UUID(), logger = logger
        logger.notice("Correction started: request=\(requestID.uuidString, privacy: .public) provider=\(self.providerID, privacy: .public) auth=\(self.authentication, privacy: .public) model=\(self.model, privacy: .public) characters=\(request.text.count)")
        do {
            let provider = provider, timeout = timeout
            let input = AITextRequest(model: model, instructions: TranscriptEditPolicy.instructions(language: request.language), text: request.text, latency: .interactive, options: options, requestID: requestID, onProgress: { event in
                logger.notice("Request phase: request=\(requestID.uuidString, privacy: .public) phase=\(event.stage.rawValue, privacy: .public) seconds=\(event.elapsedSeconds) status=\(event.statusCode ?? -1)")
                if let usage = event.usage {
                    logger.notice("Request usage: request=\(requestID.uuidString, privacy: .public) input=\(usage.inputTokens ?? -1) output=\(usage.outputTokens ?? -1) cached=\(usage.cachedInputTokens ?? -1) reasoning=\(usage.reasoningTokens ?? -1)")
                }
            })
            let text = try await withThrowingTaskGroup(of: String.self) { tasks in
                tasks.addTask { try await provider.generate(input) }
                tasks.addTask { try await Task.sleep(for: timeout); throw URLError(.timedOut) }
                defer { tasks.cancelAll() }
                return try await tasks.next()!
            }
            let validated = try TranscriptEditPolicy.validate(text, original: request.text)
            logger.notice("Correction completed: request=\(requestID.uuidString, privacy: .public) seconds=\(Date().timeIntervalSince(started)) characters=\(validated.count)")
            return .init(text: validated, modelID: model)
        } catch {
            let errorInfo = error as NSError
            logger.error("Correction failed: request=\(requestID.uuidString, privacy: .public) seconds=\(Date().timeIntervalSince(started)) domain=\(errorInfo.domain, privacy: .public) code=\(errorInfo.code)")
            throw error
        }
    }
    public func unload() async {}
}
