import Foundation
import CoreML
import FluidAudio
import HuggingFace
import MurmurCore
import WhisperKit

/// Whisper language detection on bounded speech audio, independently of ASR
/// and text editing providers. Never transcribes or uploads the recording.
public actor SpeechLanguageDetector {
    public static let detectorRepository = "argmaxinc/whisperkit-coreml"
    public static let detectorRevision = "f11270c0247abbe2072c4a2b48dcb7268cac6686"
    private static let tokenizerRevision = "e37978b90ca9030d5170a5c07aadb050351a65bb"
    private var detector: WhisperKit?
    public init() {}

    public static func storageLocation() -> ModelStorageLocation {
        let cache = HubCache.default
        let repo = Repo.ID(rawValue: detectorRepository)!
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(detectorRevision)
        return .init(id: "speech/text-language", root: cache.cacheDirectory,
                     directory: cache.repoDirectory(repo: repo, kind: .model),
                     title: "Language detection for text editing", detail: "Used by optional text post-processing.",
                     markers: [snapshot.appendingPathComponent("murmur-language-ready")])
    }

    public func prepare(progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in }) async throws {
        guard detector == nil else { return }
        let cache = HubCache.default
        let client = HubClient(cache: cache)
        let repo = Repo.ID(rawValue: Self.detectorRepository)!
        let snapshot = cache.snapshotsDirectory(repo: repo, kind: .model).appendingPathComponent(Self.detectorRevision)
        let root = snapshot.appendingPathComponent("openai_whisper-base")
        let marker = snapshot.appendingPathComponent("murmur-language-ready")
        if !FileManager.default.fileExists(atPath: marker.path) {
            let entries = try await client.listFiles(in: repo, kind: .model, revision: Self.detectorRevision, recursive: true)
            let files = entries.filter {
                $0.type == .file && $0.path.hasPrefix("openai_whisper-base/") && !$0.path.contains(".mlpackage/")
            }.map(\.path).sorted()
            guard !files.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            _ = try await client.downloadSnapshot(of: repo, kind: .model, revision: Self.detectorRevision,
                                                  matching: files, progressHandler: progress)
            let tokenizerRepo = Repo.ID(rawValue: "openai/whisper-base")!
            let tokenizerRoot = try await client.downloadSnapshot(of: tokenizerRepo, kind: .model,
                revision: Self.tokenizerRevision,
                matching: ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.json", "merges.txt"],
                progressHandler: progress)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "vocab.json", "merges.txt"] {
                let destination = root.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try Self.installTokenizerFile(from: tokenizerRoot.appendingPathComponent(name), to: destination)
                }
            }
        }
        do {
            detector = try await WhisperKit(WhisperKitConfig(modelFolder: root.path, tokenizerFolder: root,
                computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                                                   textDecoderCompute: .cpuAndNeuralEngine),
                verbose: false, prewarm: false, load: true, download: false))
            try Task.checkCancellation()
            try Data(Self.detectorRevision.utf8).write(to: marker, options: .atomic)
        } catch {
            await close()
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }

    /// Hub snapshots may link relatively to their repository's blob directory.
    /// Copying the link into another repository breaks its target. An atomic
    /// data write follows the source link and also replaces old dangling links.
    static func installTokenizerFile(from source: URL, to destination: URL) throws {
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }

    public func detect(url: URL) async throws -> String? {
        try Task.checkCancellation()
        guard let detector else { throw CocoaError(.featureUnsupported) }
        let vad = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
        let reader = try AudioFilePCMReader(url: url)
        var state = VadStreamState.initial()
        var languageAudio: [Float] = []
        // Ignore leading/intermittent silence; retain at most 30 seconds of speech.
        while languageAudio.count < 30 * 16_000, let frame = try reader.next() {
            try Task.checkCancellation()
            let value = try await vad.processStreamingChunk(frame, state: state)
            state = value.state
            if value.probability >= 0.5 { languageAudio.append(contentsOf: frame.prefix(30 * 16_000 - languageAudio.count)) }
        }
        guard !languageAudio.isEmpty else { return nil }
        // WhisperKit 1.1.0 spells its array API `detectLangauge`.
        let detection = try await detector.detectLangauge(audioArray: languageAudio)
        try Task.checkCancellation()
        return detection.language == "no" ? "nb" : detection.language
    }

    public func close() async {
        if let detector { await detector.unloadModels() }
        detector = nil
    }
}
