import Foundation
import HuggingFace
import MLX
import MurmurCore
import Tokenizers

/// Language-specialized provider: raw text enters a T5 encoder, not a chat prompt.
public actor SageTranscriptEditor: TranscriptEditing {
    public static let smallRevision = "ed51b4a46603931380951a3d8456685c9215864f"
    public static let largeRevision = "5a7a9960c8f0743eec57fa2fc8c034cc1dc8326a"
    private var model: SageT5?
    private var tokenizer: (any Tokenizers.Tokenizer)?
    private var loadedChoice: LocalTextModel?
    private let onCandidate: (@Sendable (TranscriptEditResult) -> Void)?
    public init(onCandidate: (@Sendable (TranscriptEditResult) -> Void)? = nil) { self.onCandidate = onCandidate }

    /// The original GPT2-style FRED tokenizer ships vocab/merges instead of
    /// tokenizer.json. Synthesize equivalent ByteLevel BPE metadata locally.
    private func prepareTokenizer(root: URL) throws {
        let destination = root.appendingPathComponent("tokenizer.json")
        let vocabulary = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("vocab.json")))
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tokenizer_config.json"))) as? [String: Any]
        let added = config?["added_tokens_decoder"] as? [String: [String: Any]] ?? [:]
        let tokens = added.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap { id, value -> [String: Any]? in
            guard let id = Int(id) else { return nil }
            var token = value; token["id"] = id
            return token
        }
        guard let bos = config?["bos_token"] as? String,
              let bosEntry = added.first(where: { $0.value["content"] as? String == bos }),
              let bosID = Int(bosEntry.key) else { throw CocoaError(.fileReadCorruptFile) }
        let special: [String: Any] = ["SpecialToken": ["id": bos, "type_id": 0]]
        let sequence: [String: Any] = ["Sequence": ["id": "A", "type_id": 0]]
        let postProcessor: [String: Any] = ["type": "TemplateProcessing", "single": [special, sequence],
            "pair": [special, sequence, special, ["Sequence": ["id": "B", "type_id": 0]]],
            "special_tokens": [bos: ["id": bos, "ids": [bosID], "tokens": [bos]]]]
        let merges = try String(contentsOf: root.appendingPathComponent("merges.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.map(String.init)
        let byteLevel: [String: Any] = ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": true]
        let data: [String: Any] = ["version": "1.0", "truncation": NSNull(), "padding": NSNull(),
            "added_tokens": tokens, "normalizer": NSNull(), "pre_tokenizer": byteLevel,
            "post_processor": postProcessor, "decoder": byteLevel,
            "model": ["type": "BPE", "dropout": NSNull(), "unk_token": NSNull(), "continuing_subword_prefix": "",
                      "end_of_word_suffix": "", "fuse_unk": false, "byte_fallback": false, "vocab": vocabulary, "merges": merges]]
        try JSONSerialization.data(withJSONObject: data).write(to: destination, options: .atomic)
    }
    private func load(_ choice: LocalTextModel) async throws {
        if loadedChoice == choice, model != nil { return }
        await unload()
        let revision = choice == .sageLarge ? Self.largeRevision : Self.smallRevision
        let repo = Repo.ID(rawValue: choice.repository)!
        let cache = HubCache.default
        let root = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(revision)
        let marker = root.appendingPathComponent("murmur-sage-ready")
        if !FileManager.default.fileExists(atPath: marker.path) {
            _ = try await HubClient(cache: cache).downloadSnapshot(of: repo, kind: .model, revision: revision,
                matching: ["config.json", "model.safetensors", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt"])
        }
        do {
            try prepareTokenizer(root: root)
            let tokenizer = try await AutoTokenizer.from(modelFolder: root)
            let configuration = try JSONDecoder().decode(SageT5Configuration.self, from: Data(contentsOf: root.appendingPathComponent("config.json")))
            let model = try Device.withDefaultDevice(.gpu) {
                let weights = try loadArrays(url: root.appendingPathComponent("model.safetensors"))
                return try SageT5(configuration: configuration, weights: weights)
            }
            try Task.checkCancellation()
            self.model = model; self.tokenizer = tokenizer; loadedChoice = choice
            try Data(revision.utf8).write(to: marker, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }
    public func prepare(language: String, modelID: String?) async throws {
        guard language == "ru" else { throw CocoaError(.featureUnsupported) }
        let choice: LocalTextModel = modelID == LocalTextModel.sageLarge.rawValue || modelID == LocalTextModel.sageLarge.repository ? .sageLarge : .sage95
        try await load(choice)
    }
    public func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        guard request.language == "ru" else { throw CocoaError(.featureUnsupported) }
        let choice: LocalTextModel = request.modelID == LocalTextModel.sageLarge.rawValue || request.modelID == LocalTextModel.sageLarge.repository ? .sageLarge : .sage95
        try await load(choice)
        try Task.checkCancellation()
        guard let model, let tokenizer, let bos = tokenizer.convertTokenToId("<LM>") else { throw CocoaError(.fileReadCorruptFile) }
        var text = ""
        for span in TranscriptEditPolicy.cyrillicSpans(request.text) {
            guard span.editable else { text += span.text; continue }
            let input = [bos] + tokenizer.encode(text: span.text.trimmingCharacters(in: .whitespacesAndNewlines), addSpecialTokens: false)
            let output: [Int]
            do {
                output = try Device.withDefaultDevice(.gpu) { try model.generate(input, maximumTokens: min(1_536, input.count * 2 + 32)) }
            } catch SageT5Error.inputTooLong { throw TranscriptEditError.inputTooLong }
            catch SageT5Error.generationLimit { throw TranscriptEditError.truncatedOutput }
            try Task.checkCancellation()
            text += span.text.prefix(while: \.isWhitespace)
            text += tokenizer.decode(tokens: output, skipSpecialTokens: true).trimmingCharacters(in: .whitespacesAndNewlines)
            text += String(span.text.reversed().prefix(while: \.isWhitespace).reversed())
        }
        onCandidate?(.init(text: text, modelID: choice.repository))
        return .init(text: try TranscriptEditPolicy.validate(text, original: request.text), modelID: choice.repository)
    }
    public func unload() async { model = nil; tokenizer = nil; loadedChoice = nil; Memory.clearCache() }
}
