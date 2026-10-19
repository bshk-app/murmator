import Foundation

/// Murmur's wrapper around `TwoTierEngine`. Loads models lazily per mode, then
/// opens a fresh session per utterance. MLX work is serialized on one queue.
final class STTEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "murmur.stt")
    private var engine: TwoTierEngine?
    private var session: UtteranceSession?
    private var captions: CaptionEngine?
    private let languageCodesLock = NSLock()
    private var languageCodes = ["auto"]
    private let memoryLimitBytes: Int
    private let parakeetANE: Bool

    init(memoryLimitBytes: Int = TwoTierEngine.defaultMemoryLimitBytes, parakeetANE: Bool = false) {
        self.memoryLimitBytes = memoryLimitBytes
        self.parakeetANE = parakeetANE
    }

    /// Ready to record in `mode` — its models are loaded and warmed.
    func isReady(_ mode: DictationMode) -> Bool {
        queue.sync { engine?.isReady(mode) ?? false }
    }

    var supportedLanguageCodes: [String] {
        languageCodesLock.lock()
        defer { languageCodesLock.unlock() }
        return languageCodes
    }

    /// Download (first run) + load + warm ONLY the models `mode` needs. Idempotent
    /// and memoized, so switching modes loads just the missing model.
    func prepare(_ mode: DictationMode) async throws {
        try await load(warming: mode) { try await $0.prepare(mode) }
    }

    /// Load both models plus the Silero boundary detector. The same weights
    /// `.hybrid` uses, so switching between dictation and captions loads nothing
    /// new — provided both pipelines were built from one `SpeechModels`.
    func prepareCaptions() async throws {
        try await load(warming: .hybrid) { try await $0.prepareCaptions() }
    }

    /// Shared shape of both loads: reuse or build the engine, run the caller's
    /// async fetch, publish the language list, then warm.
    ///
    /// Warming matters more than it looks: the first inference JIT-compiles every
    /// Metal kernel, tens of seconds of stalls, and doing it here keeps that off
    /// the user's first utterance. Re-warming an already-JIT'd model is cheap.
    private func load(
        warming mode: DictationMode,
        _ fetch: (TwoTierEngine) async throws -> Void
    ) async throws {
        let engine = queue.sync { () -> TwoTierEngine in
            if let existing = self.engine { return existing }
            let made = TwoTierEngine(memoryLimitBytes: memoryLimitBytes, parakeetANE: parakeetANE)
            self.engine = made
            return made
        }
        try await fetch(engine)                          // async fromPretrained (memoized)
        let codes = engine.supportedLanguageCodes
        languageCodesLock.lock()
        languageCodes = codes
        languageCodesLock.unlock()
        queue.sync {
            // Synthetic silence still has to run the batch model to compile its
            // kernels. Normal utterances enable trimming only after warm-up.
            if let warm = engine.makeSession(for: mode, language: nil, trimBatch: false) {
                _ = warm.step([Float](repeating: 0, count: 16000))
                _ = warm.finishText()
            }
        }
    }

    /// Open a clean session for a new utterance.
    func begin(language: String?, mode: DictationMode) {
        queue.sync {
            session = engine?.makeSession(for: mode, language: language)
        }
    }

    /// Stop the live draft. Capture leftover is still appended for the batch final.
    func releaseLive() {
        queue.sync { session?.releaseLive() }
    }

    /// Stop accepting live inference and discard an interrupted utterance
    /// without scheduling a batch pass (e.g. an iOS app leaving foreground).
    func cancel() {
        queue.sync { session = nil }
    }

    /// Feed one 16 kHz mono chunk. The live model sees every sample so its
    /// streaming state stays continuous.
    @discardableResult
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        queue.sync {
            session?.step(samples) ?? ("", "")
        }
    }

    /// Flush and end the utterance; returns the batch-final transcript.
    func finish(capturedPeakRMS: Float? = nil) -> String {
        queue.sync {
            let text = session?.finishText(peakRMS: capturedPeakRMS) ?? ""
            session = nil
            return text
        }
    }

    // MARK: captions

    func captionsReady() -> Bool {
        queue.sync { engine?.captionsReady ?? false }
    }

    /// Open a caption session. Unlike dictation this one outlives many phrases —
    /// it ends when the user stops captions, not at the next pause.
    func beginCaptions(language: String?,
                       maxEpochSeconds: Double = CaptionEngine.defaultMaxEpochSeconds) {
        queue.sync {
            captions = engine?.makeCaptionEngine(language: language, maxEpochSeconds: maxEpochSeconds)
        }
    }

    /// Feed one chunk and return the overlay's view of the talk so far.
    func stepCaptions(_ samples: [Float]) -> CaptionSnapshot? {
        queue.sync {
            guard let captions else { return nil }
            captions.step(samples)
            return captions.snapshot()
        }
    }

    /// Close the open phrase and end the session.
    func finishCaptions() -> CaptionSnapshot? {
        queue.sync {
            guard let captions else { return nil }
            captions.finish()
            let snapshot = captions.snapshot()
            self.captions = nil
            return snapshot
        }
    }
}
