import Foundation

/// Selects one contiguous batch window; the streaming lane never uses this.
enum BatchAudioTrim {
    static let frameSamples = 512
    static let marginFrames = 8 // 256 ms on each side protects boundary syllables.

    static func samples(_ audio: [Float], peakRMS: Float? = nil, detector: SpeechBoundaryDetector) -> [Float] {
        // A stop-time scan neither inherits nor leaves a talk's streaming state.
        detector.reset()
        defer { detector.reset() }
        return samples(audio, peakRMS: peakRMS, isSpeech: detector.isSpeech)
    }

    /// A nonzero floor requires microphone calibration. Until then, only exact
    /// digital silence may be discarded when the detector finds no speech.
    static func samples(
        _ audio: [Float],
        peakRMS: Float? = nil,
        silenceFloorRMS: Float = 0,
        isSpeech: ([Float]) -> Bool = { _ in false }
    ) -> [Float] {
        guard !audio.isEmpty else { return [] }
        precondition(silenceFloorRMS.isFinite && silenceFloorRMS >= 0)
        // A capture's larger resampler blocks can contain more energy than a
        // VAD frame. Use the stronger signal; never weaken a captured peak.
        var peak = Double(peakRMS ?? 0)
        guard peak.isFinite else { return audio }
        var firstSpeech: Int?
        var lastSpeechEnd = 0
        for start in stride(from: 0, to: audio.count, by: frameSamples) {
            let end = min(start + frameSamples, audio.count)
            var frame = Array(audio[start..<end])
            // Double avoids underflow silently swallowing very quiet Float PCM.
            let energy = frame.reduce(0.0) { $0 + Double($1) * Double($1) }
            guard energy.isFinite else { return audio }
            peak = max(peak, (energy / Double(frame.count)).squareRoot())
            // Silero requires 512 samples, but padding must not enter the batch.
            frame.append(contentsOf: repeatElement(0, count: frameSamples - frame.count))
            if isSpeech(frame) {
                if firstSpeech == nil { firstSpeech = start }
                lastSpeechEnd = end
            }
        }
        if let firstSpeech {
            let margin = marginFrames * frameSamples
            let start = max(0, firstSpeech - margin)
            let end = min(audio.count, lastSpeechEnd + margin)
            return Array(audio[start..<end])
        }
        // VAD failure or a false negative must not swallow audible content.
        // Equality is preserved at a calibrated floor; exact zero is always silent.
        return peak == 0 || peak < Double(silenceFloorRMS) ? [] : audio
    }
}
