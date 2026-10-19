import Foundation

/// Captions policy: a continuous live draft, corrected phrase by phrase by the
/// batch model while the talk is still going.
///
/// Model-free by construction — the live lane and the batch pass arrive as
/// closures, so the whole lifecycle (when an epoch restarts, which audio a
/// correction sees, what the overlay shows) is testable without MLX.
///
/// Both boundaries end the live epoch: Nemotron retains all PCM and rebuilds mel
/// from the whole epoch, so a real pause and the safety cap both have to bound it.
/// The cap restarts immediately at the same audio position; the batch correction
/// remains authoritative while the fresh provisional draft resumes.
public final class CaptionEngine {
    public struct LiveLane {
        public let begin: () -> Void
        public let step: ([Float]) -> Void
        public let text: () -> String
        public let finish: () -> Void
        public init(begin: @escaping () -> Void, step: @escaping ([Float]) -> Void, text: @escaping () -> String, finish: @escaping () -> Void) { self.begin = begin; self.step = step; self.text = text; self.finish = finish }
    }

    public static let sampleRate = 16_000
    /// Suggested visible window for compact overlays, not a transcript retention limit.
    public static let confirmedHistory = 24

    /// Longest a phrase may run without a pause before it is corrected anyway.
    /// Measured: a 60 s Parakeet pass costs ~0.45 s, so a monologue of unbroken
    /// speech is bounded by this rather than by the speaker.
    public static let defaultMaxEpochSeconds: Double = 60

    private let live: LiveLane
    private let isSpeech: ([Float]) -> Bool
    private let batch: (Range<Int>, [Float]) -> String
    private let enqueueCorrection: ((UInt64, Range<Int>, [Float]) -> Void)?
    private let frameSamples = 512      // Silero's 32 ms frame
    private let preRollSamples: Int

    private var policy: SpeechBoundaryPolicy
    private var transcript = CaptionTranscript()
    private var audio = CaptionAudioBuffer()
    private var frameRemainder: [Float] = []
    private var openSegment: UInt64?
    private var epochOpen = false

    public init(
        live: LiveLane,
        isSpeech: @escaping ([Float]) -> Bool,
        batch: @escaping (Range<Int>, [Float]) -> String,
        endpointSilence: Double = 0.48,
        preRoll: Double = 0.288,
        maxEpochSeconds: Double = CaptionEngine.defaultMaxEpochSeconds,
        enqueueCorrection: ((UInt64, Range<Int>, [Float]) -> Void)? = nil
    ) {
        self.live = live
        self.isSpeech = isSpeech
        self.preRollSamples = Int(preRoll * Double(Self.sampleRate))
        self.batch = batch
        self.enqueueCorrection = enqueueCorrection
        let rate = Double(Self.sampleRate)
        self.policy = SpeechBoundaryPolicy(
            frameSamples: frameSamples,
            preRollSamples: Int(preRoll * rate),
            endpointSilenceFrames: max(1, Int((endpointSilence * rate) / Double(frameSamples))),
            maxEpochSamples: Int(maxEpochSeconds * rate)
        )
    }

    /// Feed one mic chunk.
    ///
    /// Work is per 512-sample frame, not per chunk: the VAD verdict for a frame
    /// decides whether that same frame reaches the live lane. Feeding the whole
    /// chunk first would hand the samples after an endpoint to the epoch that just
    /// ended, and would keep a live epoch running through silence — the two ways
    /// this loop stops being affordable over an hour.
    public func step(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        audio.append(chunk)
        frameRemainder.append(contentsOf: chunk)
        while frameRemainder.count >= frameSamples {
            let frame = Array(frameRemainder.prefix(frameSamples))
            frameRemainder.removeFirst(frameSamples)
            let event = policy.frame(isSpeech: isSpeech(frame))
            if case let .opened(startSample) = event, !epochOpen {
                beginEpoch()
                // VAD confirms speech after its onset. Recover the retained
                // earlier PCM for the live model too, not only for the batch
                // correction. The current frame follows once, below.
                let frameStart = policy.consumedSamples - frameSamples
                let preRoll = startSample ..< frameStart
                if !preRoll.isEmpty { live.step(audio.slice(preRoll)) }
            }
            if epochOpen { live.step(frame) }
            if let event {
                apply(event)
            } else if let id = openSegment {
                transcript.updateProvisional(id, text: draftText())
            }
        }
        releaseSilentAudio()
    }

    /// Close the open phrase, once. The tail past the last whole frame is part of
    /// the phrase, so the range runs to the end of captured audio.
    public func finish() {
        if let event = policy.finish(endSample: audio.endSample) { apply(event) }
        if epochOpen { live.finish(); epochOpen = false }
        frameRemainder.removeAll(keepingCapacity: false)
    }

    public func snapshot() -> CaptionSnapshot { transcript.snapshot() }
    public var isUtteranceOpen: Bool { openSegment != nil }

    /// Called on the policy owner's executor when a separate backend finishes.
    /// Segment IDs prevent a late correction from replacing newer speech.
    public func applyCorrection(_ id: UInt64, text: String, replacing ids: [UInt64]? = nil) {
        if let ids { transcript.confirm(id, text: text, replacing: ids) }
        else { transcript.confirm(id, text: text) }
    }

    /// Samples held for the batch pass — the buffer this loop must keep bounded.
    public var bufferedSamples: Int { audio.count }

    // MARK: boundaries

    /// With no phrase open, only the next phrase's pre-roll can still be needed;
    /// everything older is released so a long pause costs nothing. A forced cut
    /// never reaches back further than that (see `forcedCutPoint`), so this one
    /// rule covers both kinds of boundary.
    private func releaseSilentAudio() {
        guard openSegment == nil else { return }
        audio.discard(before: policy.consumedSamples - preRollSamples)
    }

    /// The live lane's text for the current phrase. A forced cap starts a fresh
    /// live session, so nothing from the confirmed phrase can remain in this text.
    private func draftText() -> String { live.text() }

    private func apply(_ event: SpeechBoundaryEvent) {
        switch event {
        case let .opened(startSample):
            openSegment = transcript.open(startSample: startSample)
            transcript.updateProvisional(openSegment!, text: draftText())

        case let .closed(range, forced):
            let id = openSegment ?? transcript.open(startSample: range.lowerBound)
            openSegment = nil
            transcript.close(id, endSample: range.upperBound)

            // Both boundaries end the live epoch. Nemotron retains every PCM
            // sample and rebuilds mel from the whole epoch, so preserving it across
            // caps makes memory and per-step work unbounded. The batch correction
            // is authoritative; restart the provisional lane at the cut instead.
            if epochOpen {
                live.finish()
                // `finish` can emit trailing Nemotron tokens. Refresh the fallback
                // before batch confirmation; an empty Parakeet result keeps this
                // flushed draft rather than the stale pre-finish text.
                transcript.updateProvisional(id, text: live.text())
                epochOpen = false
            }
            correct(id, range: range)

            guard forced else { return }
            // A gap-based cut reserves up to one pre-roll of already captured
            // speech. Only that case needs an immediate epoch/segment so Stop can
            // close the tail. A cursor cut owns no tail and waits for the next
            // speech frame; opening now would orphan an empty epoch in silence.
            let replayRange = range.upperBound ..< policy.consumedSamples
            guard !replayRange.isEmpty else { return }

            beginEpoch()
            openSegment = transcript.open(startSample: range.upperBound)
            live.step(audio.slice(replayRange))
            if let openSegment {
                transcript.updateProvisional(openSegment, text: draftText())
            }
        }
    }

    /// Run the batch pass over one phrase and install its text.
    ///
    /// Everything up to the phrase's end is released here. Segments never
    /// overlap — the policy floors a reopen at the previous end — so no later
    /// phrase can want these samples back. Holding the *next* phrase's pre-roll
    /// is `releaseSilentAudio`'s job, and it has the cursor to do it exactly.
    private func correct(_ id: UInt64, range: Range<Int>) {
        guard audio.contains(range) else {
            // Not reachable with contiguous ranges; keep the draft rather than
            // blank the line, and say so instead of failing silently.
            assertionFailure("caption range \(range) is no longer buffered")
            transcript.confirm(id, text: "")
            return
        }
        let samples = audio.slice(range)
        if let enqueueCorrection {
            enqueueCorrection(id, range, samples)
        } else {
            transcript.confirm(id, text: batch(range, samples))
        }
        audio.discard(before: range.upperBound)
    }

    /// Start one bounded live epoch.
    private func beginEpoch() {
        live.begin()
        epochOpen = true
    }
}

/// Absolute-addressed audio for the batch lane: phrases are handed over as
/// sample ranges, and everything a correction has consumed is dropped.
struct CaptionAudioBuffer {
    private var samples: [Float] = []
    private var base = 0            // absolute index of samples[0]

    var endSample: Int { base + samples.count }
    var count: Int { samples.count }

    mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    public func contains(_ range: Range<Int>) -> Bool {
        range.lowerBound >= base && range.upperBound <= endSample
    }

    public func slice(_ range: Range<Int>) -> [Float] {
        guard contains(range) else { return [] }
        return Array(samples[(range.lowerBound - base) ..< (range.upperBound - base)])
    }

    mutating func discard(before sample: Int) {
        let drop = min(max(0, sample - base), samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        base += drop
    }
}
