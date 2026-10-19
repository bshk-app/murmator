import XCTest
@testable import MurmurKit

final class TwoPassSessionTests: XCTestCase {
    func test_digital_silence_skips_batch_without_changing_the_live_feed() {
        var live: [[Float]] = []
        var batchCalls = 0
        let session = TwoPassSession(
            liveStep: { live.append($0) },
            liveText: { "spurious draft" },
            liveFinish: {},
            batch: { _ in batchCalls += 1; return "hallucinated final" }
        )
        let chunks = [
            [Float](repeating: 0, count: 127),
            [Float](repeating: 0, count: 512),
            [Float](repeating: 0, count: 111_361),
        ]
        for chunk in chunks { _ = session.step(chunk) }

        XCTAssertEqual(live, chunks, "silence must still reach the streaming model unchanged")
        XCTAssertEqual(session.finishText(), "", "silent audio must not paste a hallucination")
        XCTAssertEqual(batchCalls, 0, "the final recognizer must not run on digital silence")
    }

    func test_empty_capture_skips_batch() {
        var batchCalls = 0
        let session = TwoPassSession(
            liveStep: { _ in }, liveText: { "" }, liveFinish: {},
            batch: { _ in batchCalls += 1; return "hallucinated final" }
        )

        XCTAssertEqual(session.finishText(), "")
        XCTAssertEqual(batchCalls, 0)
    }

    func test_only_the_batch_lane_is_trimmed_at_stop() {
        let frame = BatchAudioTrim.frameSamples
        let audio = [Float](repeating: 0, count: 20 * frame) +
                    [Float](repeating: 0.1, count: frame) + [Float](repeating: 0, count: 20 * frame)
        var live: [Float] = []
        var detectorCalls = 0
        var batched: [Float] = []
        let session = TwoPassSession(
            liveStep: { live.append(contentsOf: $0) }, liveText: { "draft" }, liveFinish: {},
            batch: { batched = $0; return "final" },
            batchInput: { samples, peak in
                BatchAudioTrim.samples(samples, peakRMS: peak, isSpeech: {
                    detectorCalls += 1
                    return $0.contains { $0 > 0 }
                })
            }
        )
        // Deliberately misalign live chunks with the 512-sample VAD frame.
        for start in stride(from: 0, to: audio.count, by: 613) {
            _ = session.step(Array(audio[start..<min(start + 613, audio.count)]))
        }

        XCTAssertEqual(live, audio)
        XCTAssertEqual(detectorCalls, 0, "the live lane must not be VAD gated")
        XCTAssertEqual(session.finishText(peakRMS: 0.1), "final")
        XCTAssertEqual(batched, Array(audio[(12 * frame)..<(29 * frame)]))
        XCTAssertEqual(detectorCalls, 41)
    }

    func test_warm_up_can_explicitly_bypass_silence_trimming() {
        var calls = 0
        let silence = [Float](repeating: 0, count: 16_000)
        let session = TwoPassSession(
            liveStep: { _ in }, liveText: { "" }, liveFinish: {},
            batch: { XCTAssertEqual($0, silence); calls += 1; return "warm" },
            batchInput: { audio, _ in audio }
        )
        _ = session.step(silence)
        XCTAssertEqual(session.finishText(), "warm")
        XCTAssertEqual(calls, 1, "model warm-up still needs to compile the batch kernels")
    }

    /// The text that gets pasted is the batch pass, not the live draft.
    func test_finish_returns_the_batch_transcript() {
        var batched: [Float] = []
        let session = TwoPassSession(
            liveStep: { _ in },
            liveText: { "draft with errors" },
            liveFinish: {},
            batch: { samples in
                batched = samples
                return "corrected final"
            }
        )

        _ = session.step([0.1, 0.2, 0.3])
        XCTAssertEqual(session.finishText(), "corrected final")
        XCTAssertEqual(batched, [0.1, 0.2, 0.3])
    }

    /// Hotkey release must not spend more live-lane compute on leftover chunks.
    func test_release_keeps_audio_but_stops_the_live_lane() {
        var liveChunks = 0
        var liveFinished = 0
        let session = TwoPassSession(
            liveStep: { _ in liveChunks += 1 },
            liveText: { "draft" },
            liveFinish: { liveFinished += 1 },
            batch: { samples in
                XCTAssertEqual(samples, [1, 2, 3, 4])
                return "final"
            }
        )

        _ = session.step([1, 2])
        session.releaseLive()
        _ = session.step([3, 4])

        XCTAssertEqual(liveChunks, 1)
        XCTAssertEqual(session.finishText(), "final")
        XCTAssertEqual(liveFinished, 0)
    }

    /// A failed authoritative pass must not paste or auto-send an incomplete draft.
    func test_empty_batch_does_not_fall_back_to_live_text() {
        let session = TwoPassSession(
            liveStep: { _ in },
            liveText: { "incomplete draft" },
            liveFinish: {},
            batch: { _ in "" }
        )

        _ = session.step([1, 2])
        XCTAssertEqual(session.finishText(), "")
    }
}
