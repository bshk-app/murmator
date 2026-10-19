import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MurmurCore
import Tokenizers

/// Provider implementation. The orchestration depends only on TranscriptEditing,
/// so remote model selection/requests can be implemented without changing capture.
public actor LocalTranscriptEditor: TranscriptEditing {
    private var container: ModelContainer?
    private var loadedModel: LocalTextModel?
    private let sage: SageTranscriptEditor
    private let onCandidate: (@Sendable (TranscriptEditResult) -> Void)?
    /// Explicit qualification instrumentation; production callers leave it nil.
    public init(onCandidate: (@Sendable (TranscriptEditResult) -> Void)? = nil) {
        self.onCandidate = onCandidate; sage = SageTranscriptEditor(onCandidate: onCandidate)
    }

    public static func storageLocations() -> [ModelStorageLocation] {
        let cache = HubCache.default
        return LocalTextModel.allCases.map { model in
            let repo = Repo.ID(rawValue: model.repository)!
            return .init(id: "speech/text-" + model.rawValue, root: cache.cacheDirectory,
                         directory: cache.repoDirectory(repo: repo, kind: .model),
                         title: model.title, detail: "Used by optional text post-processing.")
        }
    }

    private func revision(_ model: LocalTextModel) -> String {
        switch model {
        case .sage95: return SageTranscriptEditor.smallRevision
        case .sageLarge: return SageTranscriptEditor.largeRevision
        case .qwen35: return "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
        case .lfm25: return "b41f2b65685e95418f1ac809bb022d4f79e1ab27"
        case .lfm25Compact: return "7ccafdb04c36936f4f1c4685198c6c9a40275932"
        case .gemma4: return "238767527555cb75a05732a84dff5d6ba0dd6809"
        }
    }
    private func load(_ model: LocalTextModel) async throws -> ModelContainer {
        if loadedModel == model, let container { return container }
        await unload()
        let cache = HubCache.default
        let repo = Repo.ID(rawValue: model.repository)!
        let revision = revision(model)
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(revision)
        let subdirectory = model == .lfm25 ? "4bit/" : ""
        let root = subdirectory.isEmpty ? snapshot : snapshot.appendingPathComponent("4bit")
        let marker = root.appendingPathComponent("murmur-text-ready")
        if !FileManager.default.fileExists(atPath: marker.path) {
            let client = HubClient(cache: cache)
            let entries = try await client.listFiles(in: repo, kind: .model, revision: revision, recursive: true)
            let files = entries.filter {
                $0.type == .file && $0.path.hasPrefix(subdirectory) && ["json", "safetensors", "txt", "jinja", "model"].contains(URL(fileURLWithPath: $0.path).pathExtension)
            }.map(\.path).sorted()
            _ = try await client.downloadSnapshot(of: repo, kind: .model, revision: revision, matching: files)
        }
        do {
            let loaded = try await Device.withDefaultDevice(.gpu) {
                try await LLMModelFactory.shared.loadContainer(from: root, using: #huggingFaceTokenizerLoader())
            }
            try Task.checkCancellation()
            try Data(revision.utf8).write(to: marker, options: .atomic)
            container = loaded; loadedModel = model
            return loaded
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }
    public func prepare(language: String, modelID: String?) async throws {
        try Task.checkCancellation()
        let model = LocalTextModel.resolve(language: language, modelID: modelID)
        if model == .sage95 || model == .sageLarge {
            container = nil; loadedModel = nil
            try await sage.prepare(language: language, modelID: model.rawValue)
        } else {
            await sage.unload()
            _ = try await load(model)
        }
    }
    public func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        try Task.checkCancellation()
        guard request.text.count <= TranscriptEditPolicy.maximumCharacters else { throw TranscriptEditError.inputTooLong }
        let model = LocalTextModel.resolve(language: request.language, modelID: request.modelID)
        if model == .sage95 || model == .sageLarge {
            container = nil; loadedModel = nil
            return try await sage.edit(.init(text: request.text, language: request.language, modelID: model.rawValue))
        }
        await sage.unload()
        let container = try await load(model)
        // Fresh history per section: preceding requests cannot become instructions
        // or contaminate the next section's output. No tools or thinking required.
        let session = ChatSession(container, instructions: TranscriptEditPolicy.instructions(language: request.language),
            generateParameters: .init(maxTokens: 2_048, temperature: 0),
            additionalContext: ["enable_thinking": false])
        var output = ""
        var completed = false
        let prompt = request.text
        for try await event in session.streamDetails(to: prompt) {
            try Task.checkCancellation()
            switch event {
            case .chunk(let text): output += text
            case .info(let info):
                guard info.stopReason == .stop else { throw TranscriptEditError.truncatedOutput }
                completed = true
            case .toolCall: throw TranscriptEditError.invalidOutput
            }
        }
        guard completed else { throw TranscriptEditError.invalidOutput }
        try Task.checkCancellation()
        // LFM2.5 2.6B always reasons. Only its final answer is editable content.
        if let boundary = output.range(of: "</think>") { output = String(output[boundary.upperBound...]) }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("\""), output.hasSuffix("\""),
           !request.text.hasPrefix("\""), !request.text.hasSuffix("\""), output.count >= 2 {
            output = String(output.dropFirst().dropLast())
        }
        onCandidate?(.init(text: output, modelID: model.repository))
        return .init(text: try TranscriptEditPolicy.validate(output, original: request.text), modelID: model.repository)
    }
    public func unload() async {
        container = nil; loadedModel = nil
        await sage.unload()
        Memory.clearCache()
    }
}
