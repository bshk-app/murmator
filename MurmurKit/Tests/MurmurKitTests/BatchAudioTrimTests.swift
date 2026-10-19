import XCTest
@preconcurrency import AVFoundation
@testable import MurmurSpeech
@testable import MurmurKit

final class BatchAudioTrimTests: XCTestCase {
    private let frame = BatchAudioTrim.frameSamples

    private func frames(_ values: [Float]) -> [Float] {
        values.flatMap { [Float](repeating: $0, count: frame) }
    }

    func testTrimsOnlyTheLeadingAndTrailingSilenceWithMargins() {
        let audio = frames([Float](repeating: 0, count: 20) + [0.1, 0.2] + [Float](repeating: 0, count: 20))
        let trimmed = BatchAudioTrim.samples(audio, isSpeech: { $0.contains { $0 > 0 } })

        XCTAssertEqual(trimmed, Array(audio[(12 * frame)..<(30 * frame)]))
        XCTAssertLessThan(trimmed.count, audio.count)
    }

    func testInteriorPauseSurvivesInOneContiguousWindow() {
        let audio = frames([Float](repeating: 0, count: 20) + [0.1] +
                           [Float](repeating: 0, count: 30) + [0.2] + [Float](repeating: 0, count: 20))
        let trimmed = BatchAudioTrim.samples(audio, isSpeech: { $0.contains { $0 > 0 } })

        XCTAssertEqual(trimmed, Array(audio[(12 * frame)..<(60 * frame)]))
        if trimmed.count >= 39 * frame {
            XCTAssertEqual(Array(trimmed[(9 * frame)..<(39 * frame)]), frames([Float](repeating: 0, count: 30)))
        } else {
            XCTFail("the interior pause disappeared from the batch window")
        }
    }

    func testCalibratedRoomToneSkipsBatch() {
        // This is an injected fixture floor, not a production microphone threshold.
        let audio = frames([Float](repeating: 0.0001, count: 10))
        XCTAssertEqual(BatchAudioTrim.samples(audio, silenceFloorRMS: 0.001, isSpeech: { _ in false }), [])
    }

    func testMissedSpeechAboveTheFloorPassesThroughUntrimmed() {
        let audio = frames([0, 0, 0.002, 0.002, 0, 0])
        XCTAssertEqual(BatchAudioTrim.samples(audio, silenceFloorRMS: 0.001, isSpeech: { _ in false }), audio)
    }

    func testSpeechExactlyAtTheFloorIsPreserved() {
        let audio = frames([0.001])
        XCTAssertEqual(BatchAudioTrim.samples(audio, peakRMS: 0.001, silenceFloorRMS: 0.001,
                                             isSpeech: { _ in false }), audio)
    }

    func testUncalibratedFloorPreservesEvenVeryQuietMissedSpeech() {
        let audio = frames([0, 1e-30, 0])
        XCTAssertEqual(BatchAudioTrim.samples(audio, isSpeech: { _ in false }), audio)
    }

    func testDetectedQuietSpeechRunsEvenBelowTheEnergyFloor() {
        let audio = frames([Float](repeating: 0, count: 20) + [0.0001] + [Float](repeating: 0, count: 20))
        let trimmed = BatchAudioTrim.samples(audio, silenceFloorRMS: 0.001,
                                             isSpeech: { $0.contains { $0 > 0 } })
        XCTAssertEqual(trimmed, Array(audio[(12 * frame)..<(29 * frame)]))
    }

    func testPartialFinalFrameIsPaddedOnlyForTheDetector() {
        let audio = frames([Float](repeating: 0, count: 20)) + [Float](repeating: 0.1, count: 17)
        var lengths: [Int] = []
        let trimmed = BatchAudioTrim.samples(audio, isSpeech: {
            lengths.append($0.count)
            return $0.contains { $0 > 0 }
        })

        XCTAssertEqual(lengths, [Int](repeating: frame, count: 21))
        XCTAssertEqual(trimmed, Array(audio[(12 * frame)...]))
        XCTAssertEqual(trimmed.suffix(17), audio.suffix(17))
    }

    func testPeakFrameEnergyPreservesABriefQuietSignalInLongSilence() {
        let audio = frames([Float](repeating: 0, count: 100) + [0.002] + [Float](repeating: 0, count: 100))
        XCTAssertEqual(BatchAudioTrim.samples(audio, silenceFloorRMS: 0.001, isSpeech: { _ in false }), audio)
    }

    func testCapturePeakKeepsVADMissedAudio() {
        let audio = frames([0.0001])
        XCTAssertEqual(BatchAudioTrim.samples(audio, peakRMS: 0.002, silenceFloorRMS: 0.001,
                                             isSpeech: { _ in false }), audio)
    }

    func testEmptyAudioDoesNotRunTheDetector() {
        var calls = 0
        XCTAssertEqual(BatchAudioTrim.samples([], isSpeech: { _ in calls += 1; return true }), [])
        XCTAssertEqual(calls, 0)
    }

    func testSileroTrimsARealSpeechRecordingAndClearsItsState() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Prototypes/iOS/Resources/smoke-ru.wav")
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/mlx-audio/mlx-community_silero-vad/model.safetensors")
        guard FileManager.default.fileExists(atPath: fixture.path),
              FileManager.default.fileExists(atPath: cache.path) else {
            throw XCTSkip("Local speech fixture and cached Silero weights required; this test never downloads models")
        }
        let file = try AVAudioFile(forReading: fixture)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let channel = try XCTUnwrap(pcm.floatChannelData?[0])
        let speech = Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        let silence = [Float](repeating: 0, count: 48_000)
        let audio = silence + speech + silence
        let detector = try await SpeechBoundaryDetector.load()
        let queue = DispatchQueue(label: "test.batch-silero")
        queue.sync {
            detector.warmUp()
            XCTAssertEqual(BatchAudioTrim.samples(silence, detector: detector), [])
            let trimmed = BatchAudioTrim.samples(audio, detector: detector)
            XCTAssertFalse(trimmed.isEmpty)
            XCTAssertLessThan(trimmed.count, audio.count - 48_000)
            XCTAssertNil(detector.lastProbability, "the batch scan leaked VAD state into the next talk")
            XCTAssertNil(detector.lastError)
            let repeated = BatchAudioTrim.samples(audio, detector: detector)
            XCTAssertEqual(trimmed, repeated, "a previous scan changed the next recording's boundaries")
            print("Silero batch trim: \(audio.count) -> \(trimmed.count) samples")
        }
    }
}
