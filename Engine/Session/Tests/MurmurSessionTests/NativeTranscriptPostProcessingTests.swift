import Foundation
import XCTest
import MLX
import MurmurCore
import MurmurPostProcessing
@testable import MurmurSession

/// Explicit local model qualification. Ordinary tests never load models/audio.
@MainActor final class NativeTranscriptPostProcessingTests: XCTestCase {
    func testRealVoiceFinalTextUsesOneEditorRequestAndKeepsAudioSpans() async throws {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_WHOLE_TEXT_QUALIFICATION"] else {
            throw XCTSkip("Set MURMUR_WHOLE_TEXT_QUALIFICATION to the private voice-benchmark directory.")
        }
        let root = URL(fileURLWithPath: path)
        GPU.set(memoryLimit: Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.5), relaxed: false)
        var reports: [[String: Any]] = []
        for model in ["qwen35", "sageLarge"] {
            for clip in ["real_meeting_test_16k", "test_phrases_noized"] {
                let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("asr/\(clip).hybrid.json")))
                var original = RecordingTranscript()
                for utterance in fixture.utterances { original.appendSettled(utterance) }
                original.finish(fallback: fixture.finalText, endSample: fixture.utterances.last?.endSample ?? 0)
                let witness = NativeEditorWitness()
                let processor = SessionPostProcessor(editor: witness)
                let start = ProcessInfo.processInfo.systemUptime
                let result: TranscriptPostProcessingResult?
                do {
                    try await processor.prepare(progress: { _ in })
                    result = try await processor.process(url: root.appendingPathComponent("audio/\(clip).wav"),
                                                         transcript: original, modelID: model)
                } catch { await processor.close(); throw error }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let inputs = await witness.inputs, outputs = await witness.outputs
                XCTAssertEqual(inputs, [original.text], "The real editor must receive the complete final transcript.")
                let processed = try XCTUnwrap(result)
                XCTAssertEqual(processed.language, "ru")
                XCTAssertEqual(processed.transcript.utterances.map(\.id), original.utterances.map(\.id))
                XCTAssertEqual(processed.transcript.utterances.map(\.startSample), original.utterances.map(\.startSample))
                XCTAssertEqual(processed.transcript.utterances.map(\.endSample), original.utterances.map(\.endSample))
                XCTAssertEqual(processed.transcript.text, outputs.last ?? original.text)
                reports.append(["clip": clip, "model": model, "input": original.text,
                                "output": processed.transcript.text, "requests": inputs.count,
                                "language": processed.language, "appliedModel": processed.modelID ?? "declined",
                                "secondsIncludingLanguageAndLoading": seconds])
                await processor.close()
            }
        }
        let directory = root.appendingPathComponent("whole-text-1108")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("native-results.json"), options: .atomic)
    }

    private struct Fixture: Decodable {
        let finalText: String
        let utterances: [RecordedUtterance]
    }
}

private actor NativeEditorWitness: TranscriptEditing {
    private let provider = LocalTranscriptEditor()
    var inputs: [String] = []
    var outputs: [String] = []
    func edit(_ request: TranscriptEditRequest) async throws -> TranscriptEditResult {
        inputs.append(request.text)
        let result = try await provider.edit(request)
        outputs.append(result.text)
        return result
    }
    func unload() async { await provider.unload() }
}
