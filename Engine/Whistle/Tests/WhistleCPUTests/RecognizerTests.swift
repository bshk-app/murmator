import Foundation
import XCTest

@testable import WhistleCPU

final class RecognizerTests: XCTestCase {
  private func model() throws -> WhistleRecognizer {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_WEIGHTS"] else {
      throw XCTSkip("Set WHISTLE_WEIGHTS for native session checks")
    }
    return try WhistleRecognizer(weightsURL: URL(fileURLWithPath: path))
  }
  func testValidationEmptyEOFAndIndependentRuns() throws {
    let model = try model()
    let run = model.makeUtterance()
    XCTAssertThrowsError(try run.append([.nan]))
    XCTAssertThrowsError(
      try run.append(Array(repeating: 0, count: WhistleRecognizer.maximumSamples + 1)))
    XCTAssertEqual(run.sampleCount, 0)
    let empty = try run.finish()
    XCTAssertEqual(empty.text, "")
    XCTAssertTrue(empty.endedWithEOS)
    XCTAssertTrue(run.closed)
    XCTAssertThrowsError(try run.append([]))
    XCTAssertThrowsError(try run.finish())
    XCTAssertFalse(model.makeUtterance().closed)
  }
  func testSuppressedPreviewsRetainPCMWithoutComputingObsoleteDrafts() throws {
    let run = try model().makeUtterance()
    XCTAssertNil(try run.append(Array(repeating: 0, count: 48_000), allowPreview: false))
    XCTAssertEqual(run.sampleCount, 48_000)
    XCTAssertEqual(run.compute.drafts, 0)
    XCTAssertEqual(run.compute.totalSeconds, 0)
    XCTAssertEqual(run.encoderFrames, 0)
  }
  func testEarlyPreviewLeavesStreamingStateUntouched() throws {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_AUDIO_FIXTURES"] else {
      throw XCTSkip("Set WHISTLE_AUDIO_FIXTURES for the early-preview regression")
    }
    let raw = try Data(
      contentsOf: URL(fileURLWithPath: path).appendingPathComponent(
        "en_us-13542330409815692480.pcm"))
    let pcm = raw.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
    let model = try model()
    let early = model.makeUtterance()
    let control = model.makeUtterance()
    let prefix = Array(pcm.prefix(32_768))
    let draft = try early.append(prefix)
    XCTAssertNotNil(draft, "First draft must be available with 2 s of PCM")
    XCTAssertFalse(draft?.text.isEmpty ?? true)
    XCTAssertEqual(early.compute.drafts, 1)
    XCTAssertEqual(
      early.encoderFrames, 0, "Short-prefix statistics must not enter streaming caches")
    try control.append(prefix, allowPreview: false)
    for start in stride(from: prefix.count, to: pcm.count, by: 1536) {
      let chunk = Array(pcm[start..<min(start + 1536, pcm.count)])
      try early.append(chunk)
      try control.append(chunk, allowPreview: control.sampleCount + chunk.count >= 44_800)
    }
    let result = try early.finish()
    let baseline = try control.finish()
    XCTAssertTrue(result.endedWithEOS)
    XCTAssertEqual(result.ids, baseline.ids)
    XCTAssertEqual(early.encoderFrames, control.encoderFrames)
    XCTAssertEqual(early.compute.finalRetries, control.compute.finalRetries)
    XCTAssertEqual(early.compute.drafts, control.compute.drafts + 1)
  }
  func testPacedChunkSchedulePreservesAllFinalPilotTokens() throws {
    let env = ProcessInfo.processInfo.environment
    guard let decoderPath = env["WHISTLE_FIXTURES"], let audioPath = env["WHISTLE_AUDIO_FIXTURES"]
    else {
      throw XCTSkip("Set both fixture paths for streaming final parity")
    }
    struct Oracle: Decodable {
      struct Row: Decodable {
        let filename: String
        let hypothesis: String
        let ids: [Int]
      }
      let rows: [Row]
    }
    let root = URL(fileURLWithPath: decoderPath)
    let oracle = try JSONDecoder().decode(
      Oracle.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let model = try model()
    for row in oracle.rows {
      let url = URL(fileURLWithPath: audioPath).appendingPathComponent(
        row.filename.replacingOccurrences(of: ".wav", with: ".pcm"))
      let bytes = try Data(contentsOf: url)
      let pcm = bytes.withUnsafeBytes { raw in
        stride(from: 0, to: raw.count, by: 4).map {
          Float(
            bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
          )
        }
      }
      let run = model.makeUtterance()
      for start in stride(from: 0, to: pcm.count, by: 1536) {
        _ = try run.append(Array(pcm[start..<min(start + 1536, pcm.count)]))
      }
      let result = try run.finish()
      XCTAssertEqual(result.ids, row.ids, row.filename)
      XCTAssertEqual(result.text, row.hypothesis, row.filename)
      XCTAssertTrue(result.endedWithEOS)
      XCTAssertEqual(run.compute.finalRetries, 0, row.filename)
      // One isolated initial draft in addition to the cached schedule and final.
      XCTAssertLessThan(run.compute.drafts, pcm.count / 20_480 + 2)
      XCTAssertTrue(run.closed)
    }
  }
  func testCancelledRunStopsBeforeNativeWork() async throws {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_WEIGHTS"] else {
      throw XCTSkip("Set WHISTLE_WEIGHTS")
    }
    let task = Task.detached {
      let model = try WhistleRecognizer(weightsURL: URL(fileURLWithPath: path))
      let run = model.makeUtterance()
      _ = try run.append(Array(repeating: 0, count: 48_000))
    }
    task.cancel()
    do {
      try await task.value
      XCTFail("Cancelled PCM processing must throw")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
  }

  func testShiftedPhraseCompletesInsteadOfRepeating() throws {
    let run = try shiftedPhrase(start: 9792)
    let result = try run.finish()
    XCTAssertTrue(result.endedWithEOS)
    XCTAssertLessThan(result.ids.count, 100)
    XCTAssertEqual(run.compute.finalRetries, 1)
    XCTAssertTrue(result.text.contains("certification"), result.text)
    XCTAssertFalse(result.text.contains("organization rather than our organization"), result.text)
  }

  func testEOSDoesNotConfirmRepeatedEnding() throws {
    // The third phrase shifts another 100 ms. It used to repeat the ending
    // several times and then emit EOS, so an EOS-only gate missed this failure.
    let run = try shiftedPhrase(start: 11392)
    let result = try run.finish()
    XCTAssertTrue(result.endedWithEOS)
    XCTAssertEqual(run.compute.finalRetries, 1)
    XCTAssertTrue(result.text.contains("certification"), result.text)
    XCTAssertFalse(result.text.contains("organization rather than our organization"), result.text)
  }

  private func shiftedPhrase(start: Int) throws -> WhistleUtterance {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_AUDIO_FIXTURES"] else {
      throw XCTSkip("Set WHISTLE_AUDIO_FIXTURES for the long-session EOS regression")
    }
    let raw = try Data(
      contentsOf: URL(fileURLWithPath: path).appendingPathComponent(
        "en_us-13542330409815692480.pcm"))
    let pcm = raw.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
    // The second VAD phrase in the 70-second replay starts at 612 ms in the
    // source clip. The same word onset shifted by 100 ms used to exhaust all
    // 318 tokens by repeating "rather than our organization" without EOS.
    let run = try model().makeUtterance()
    try run.append(Array(pcm[start..<(start + 299008)]), allowPreview: false)
    return run
  }
}
