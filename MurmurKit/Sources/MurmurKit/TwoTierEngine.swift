import Foundation
import MLX
import MLXAudioSTT

/// Murmur's dictation composition. Caps Metal memory and loads the live
/// (Nemotron) and/or final (Parakeet) models **lazily, per mode**:
/// `prepare(.fast)` never pulls Parakeet, `prepare(.accurate)` never loads
/// Nemotron. A session accumulates audio, so each dictation needs a clean one.
///
/// Hybrid is one live stream plus one batch final — not two streaming models
/// on the same serial queue. Voxtral is not loaded.
public final class TwoTierEngine {
    public static let defaultNemotronRepo = "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
    public static let defaultParakeetRepo = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Nemotron live-chunk. 160 ms is a documented ladder rung (`[56,1]`) — 80 ms
    /// has no lookahead and a worse live WER; 320 ms only existed to cheapen a
    /// Voxtral hybrid that is gone.
    public static let defaultFastChunkMs = 160

    /// Batch-final window. 120 s bounds long-dictation attention cost while
    /// keeping enough context to avoid the tail loss measured with 30 s windows.
    public static let finalChunkDuration: Float = 120

    private let nemotronRepo: String
    private let parakeetRepo: String
    private let parakeetANE: Bool
    private let nemotronModel = AsyncMemo<NemotronASRModel>()
    private let parakeetModel = AsyncMemo<ParakeetModel>()
    private let vadModel = AsyncMemo<SpeechBoundaryDetector>()

    public static var defaultMemoryLimitBytes: Int {
        Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6)
    }

    public init(
        nemotronRepo: String = defaultNemotronRepo,
        parakeetRepo: String = defaultParakeetRepo,
        memoryLimitBytes: Int = TwoTierEngine.defaultMemoryLimitBytes,
        parakeetANE: Bool = false
    ) {
        GPU.set(memoryLimit: memoryLimitBytes, relaxed: false)
        self.nemotronRepo = nemotronRepo
        self.parakeetRepo = parakeetRepo
        self.parakeetANE = parakeetANE
    }

    public func prepare(_ mode: DictationMode) async throws {
        switch mode {
        case .fast:     _ = try await loadNemotron()
        case .accurate: _ = try await loadParakeet(); _ = try await loadVAD()
        case .hybrid:   _ = try await loadNemotron(); _ = try await loadParakeet(); _ = try await loadVAD()
        }
    }

    /// Captions need both models plus the boundary detector. Same weights as
    /// `.hybrid` — sessions built from one `SpeechModels` load one copy.
    public func prepareCaptions() async throws {
        _ = try await loadNemotron()
        _ = try await loadParakeet()
        _ = try await loadVAD()
    }

    public var captionsReady: Bool {
        nemotronModel.cached != nil && parakeetModel.cached != nil && vadModel.cached != nil
    }

    public func isReady(_ mode: DictationMode) -> Bool {
        switch mode {
        case .fast:     return nemotronModel.cached != nil
        case .accurate: return parakeetModel.cached != nil && vadModel.cached != nil
        case .hybrid:   return nemotronModel.cached != nil && parakeetModel.cached != nil && vadModel.cached != nil
        }
    }

    var supportedLanguageCodes: [String] {
        guard let nemotron = nemotronModel.cached else { return ["auto"] }
        return Self.canonicalLanguageCodes(nemotron.promptDictionary)
    }

    /// One code per prompt id: the dictionary lists several spellings of the same
    /// language ("en", "en-US"), and the picker shows one of each.
    static func canonicalLanguageCodes(_ prompts: [String: Int]) -> [String] {
        let aliasesByPrompt = Dictionary(grouping: prompts, by: { $0.value })
        let codes = aliasesByPrompt.values.compactMap { aliases in
            aliases.min { isPreferredSpelling($0.key, $1.key) }?.key
        }
        return codes.sorted {
            if $0 == "auto" { return true }
            if $1 == "auto" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// "auto" first, then bare codes ("ru"), then region-qualified ones ("en-GB"),
    /// alphabetical within a rank — the spelling a menu should show.
    private static func isPreferredSpelling(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ code: String) -> Int {
            if code == "auto" { return 0 }
            if code.count == 2 { return 1 }
            if code.contains("-") { return 2 }
            return 3
        }
        let (lhsRank, rhsRank) = (rank(lhs), rank(rhs))
        return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
    }

    private func loadNemotron() async throws -> NemotronASRModel {
        let repo = nemotronRepo
        return try await nemotronModel.get {
            try await NemotronASRModel.fromPretrained(repo)
        }
    }

    private func loadParakeet() async throws -> ParakeetModel {
        let repo = parakeetRepo
        let useANE = parakeetANE
        return try await parakeetModel.get {
            try await ParakeetModel.fromPretrained(repo, aneEncoder: useANE ? .lowPower : .off)
        }
    }

    private func loadVAD() async throws -> SpeechBoundaryDetector {
        try await vadModel.get {
            let detector = try await SpeechBoundaryDetector.load()
            // Silero's first forward JIT-compiles MLX kernels. Pay that cost while
            // the UI says Loading, then clear its state before live speech.
            detector.warmUp()
            return detector
        }
    }

    func makeSession(for mode: DictationMode, language: String? = nil, trimBatch: Bool = true) -> UtteranceSession? {
        switch mode {
        case .hybrid:   return makeHybridSession(language: language, trimBatch: trimBatch)
        case .fast:     return makeFastSession(language: language)
        case .accurate: return makeAccurateSession(trimBatch: trimBatch)
        }
    }

    /// Live Nemotron draft; pasted text is one Parakeet batch with silent ends removed.
    func makeHybridSession(language: String? = nil,
                           fastChunkMs: Int = defaultFastChunkMs,
                           trimBatch: Bool = true) -> TwoPassSession? {
        guard let nemotron = nemotronModel.cached,
              let parakeet = parakeetModel.cached,
              !trimBatch || vadModel.cached != nil else { return nil }
        let live = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs)
        return TwoPassSession(
            liveStep: { _ = live.step($0) },
            liveText: { live.text },
            liveFinish: { _ = live.finish() },
            batch: { Self.parakeetBatch(parakeet, $0) },
            batchInput: trimBatch ? { self.batchInput($0, peakRMS: $1) } : { audio, _ in audio }
        )
    }

    func makeFastSession(language: String? = nil, chunkMs: Int = defaultFastChunkMs) -> UtteranceSession? {
        guard let nemotron = nemotronModel.cached else { return nil }
        return NemotronOnlySession(nemotron, language: language, chunkMs: chunkMs)
    }

    /// No live draft — the buffer is decoded once at release.
    func makeAccurateSession(trimBatch: Bool = true) -> TwoPassSession? {
        guard let parakeet = parakeetModel.cached,
              !trimBatch || vadModel.cached != nil else { return nil }
        return TwoPassSession(
            liveStep: { _ in },
            liveText: { "" },
            liveFinish: {},
            batch: { Self.parakeetBatch(parakeet, $0) },
            batchInput: trimBatch ? { self.batchInput($0, peakRMS: $1) } : { audio, _ in audio }
        )
    }

    private func batchInput(_ audio: [Float], peakRMS: Float?) -> [Float] {
        guard let vad = vadModel.cached else { return audio }
        return BatchAudioTrim.samples(audio, peakRMS: peakRMS, detector: vad)
    }

    /// Captions: bounded Nemotron epochs corrected by Parakeet batches, with
    /// Silero marking natural seams and a safety cap bounding unbroken speech.
    ///
    /// The detector's streaming state is per talk, so it is cleared here rather
    /// than carried into the next session from whatever the last one heard.
    /// `CaptionEngine` rebuilds this live stream after both a pause and a cap:
    /// Nemotron retains all epoch PCM, so keeping one session across caps would
    /// make per-step work grow through a long monologue.
    func makeCaptionEngine(language: String? = nil,
                           fastChunkMs: Int = defaultFastChunkMs,
                           maxEpochSeconds: Double = CaptionEngine.defaultMaxEpochSeconds) -> CaptionEngine? {
        guard let nemotron = nemotronModel.cached,
              let parakeet = parakeetModel.cached,
              let vad = vadModel.cached else { return nil }
        vad.reset()
        var live: NemotronASRStreamSession?
        return CaptionEngine(
            live: CaptionEngine.LiveLane(
                begin: { live = nemotron.makeStreamSession(language: language, chunkMs: fastChunkMs) },
                step: { if let live { _ = live.step($0) } },
                text: { live?.text ?? "" },
                finish: { if let live { _ = live.finish() }; live = nil }
            ),
            isSpeech: { vad.isSpeech($0) },
            batch: { _, samples in Self.parakeetBatch(parakeet, samples) },
            maxEpochSeconds: maxEpochSeconds
        )
    }

    static func parakeetBatch(_ model: ParakeetModel, _ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        let params = STTGenerateParameters(language: nil, chunkDuration: finalChunkDuration)
        return model.generate(audio: MLXArray(samples), generationParameters: params).text
    }
}
