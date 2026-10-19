@testable import MurmurSpeech
import XCTest

/// `SpeechBoundaryPolicy` is covered in Engine/Core; the detector lives in
/// MurmurSpeech, which has no test target of its own.
final class SpeechBoundaryDetectorTests: XCTestCase {
    /// Warm-up must execute one correctly sized zero frame and then clear the
    /// streaming state, so the first live verdict starts from a clean detector.
    func test_detector_warmup_runs_one_silent_frame_then_resets() {
        var fed: [Float]?
        var resets = 0

        SpeechBoundaryDetector.performWarmUp(
            frameSamples: SpeechBoundaryDetector.frameSamples,
            feed: { fed = $0 },
            reset: { resets += 1 }
        )

        XCTAssertEqual(fed, [Float](repeating: 0, count: SpeechBoundaryDetector.frameSamples))
        XCTAssertEqual(resets, 1)
    }
}
