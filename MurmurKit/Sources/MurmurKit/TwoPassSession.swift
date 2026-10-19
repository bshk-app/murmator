import Foundation

/// Live draft plus a batch final on the same utterance audio.
///
/// The live lane is whatever the caller injects (Nemotron streaming). The batch
/// lane sees a single speech span at `finishText()` and is the pasted result.
final class TwoPassSession: UtteranceSession {
    private let liveStep: ([Float]) -> Void
    private let liveText: () -> String
    private let liveFinish: () -> Void
    private let batch: ([Float]) -> String
    private let batchInput: ([Float], Float?) -> [Float]

    private var buffer: [Float] = []
    private var liveReleased = false

    init(
        liveStep: @escaping ([Float]) -> Void,
        liveText: @escaping () -> String,
        liveFinish: @escaping () -> Void,
        batch: @escaping ([Float]) -> String,
        batchInput: @escaping ([Float], Float?) -> [Float] = {
            BatchAudioTrim.samples($0, peakRMS: $1)
        }
    ) {
        self.liveStep = liveStep
        self.liveText = liveText
        self.liveFinish = liveFinish
        self.batch = batch
        self.batchInput = batchInput
    }

    /// Stop spending compute on the live draft. Further `step`s only append audio
    /// for the batch pass — used on hotkey release so a capture backlog cannot
    /// delay paste.
    func releaseLive() {
        liveReleased = true
    }

    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        buffer.append(contentsOf: samples)
        if !liveReleased {
            liveStep(samples)
        }
        return currentText
    }

    var currentText: (confirmed: String, partial: String) { ("", liveText()) }

    func finishText() -> String {
        finishText(peakRMS: nil)
    }

    func finishText(peakRMS: Float?) -> String {
        if !liveReleased {
            liveReleased = true
            liveFinish()
        }
        let audio = batchInput(buffer, peakRMS)
        guard !audio.isEmpty else { return "" }
        let final = batch(audio)
        return final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : final
    }
}
