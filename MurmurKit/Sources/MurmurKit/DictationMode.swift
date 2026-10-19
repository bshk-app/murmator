import Foundation
import MLXAudioSTT
import MurmurCore

/// The common surface STTEngine drives per utterance, regardless of mode.
protocol UtteranceSession {
    func step(_ samples: [Float]) -> (confirmed: String, partial: String)
    var currentText: (confirmed: String, partial: String) { get }
    func finishText() -> String
    func finishText(peakRMS: Float?) -> String
    /// Stop the live lane; later `step`s must still keep the final audio.
    func releaseLive()
}

extension UtteranceSession {
    func releaseLive() {}
    func finishText(peakRMS: Float?) -> String { finishText() }
}

/// Fast lane only (Nemotron). Its accumulated text is the confirmed output; there
/// is no provisional tail because there's no slower lane to refine against.
final class NemotronOnlySession: UtteranceSession {
    private let s: NemotronASRStreamSession
    init(_ model: NemotronASRModel, language: String?, chunkMs: Int) {
        s = model.makeStreamSession(language: language, chunkMs: chunkMs)
    }
    func step(_ samples: [Float]) -> (confirmed: String, partial: String) {
        _ = s.step(samples); return (s.text, "")
    }
    var currentText: (confirmed: String, partial: String) { (s.text, "") }
    func finishText() -> String { _ = s.finish(); return s.text }
}
