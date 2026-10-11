import Foundation
import XCTest

@testable import WhistleCPU

final class AudioTests: XCTestCase {
  private func weights() throws -> WhistleWeights {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_WEIGHTS"] else {
      throw XCTSkip("Set WHISTLE_WEIGHTS for native audio model tests")
    }
    return try WhistleWeights(url: URL(fileURLWithPath: path))
  }

  private func fixtures() throws -> (URL, [[String: Any]]) {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_AUDIO_FIXTURES"] else {
      throw XCTSkip("Set WHISTLE_AUDIO_FIXTURES for independent audio oracle tests")
    }
    let root = URL(fileURLWithPath: path)
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("audio-manifest.json")))
        as? [String: Any])
    let rows = try XCTUnwrap(manifest["rows"] as? [[String: Any]])
    XCTAssertEqual(rows.count, 4)
    return (root, rows)
  }

  private func floats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
  }

  private func rmse(_ a: [Float], _ b: [Float]) -> Double {
    XCTAssertEqual(a.count, b.count)
    return sqrt(zip(a, b).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(b.count))
  }

  func testRowNumericsDoNotShareScalesAcrossFrames() {
    let x: [Float] = [1, -1, 1000, -1000]
    XCTAssertEqual(Math.quantizeRows(x, width: 2), x)
    let norms = Math.normRows(x, scale: [0, 0])
    XCTAssertEqual(norms[0], norms[2], accuracy: 1e-5)
  }

  func testFrontendRejectsInvalidPCMAndHandlesReflectionAtShortEOF() throws {
    let frontend = try WhistleFrontend(weights: weights())
    XCTAssertThrowsError(try frontend.forward(audio: []))
    XCTAssertThrowsError(try frontend.forward(audio: [.nan]))
    XCTAssertThrowsError(try frontend.forward(audio: [Float](repeating: 0, count: 960001)))
    for count in [1, 159, 160, 161, 1280, 1281] {
      let result = try frontend.forward(audio: [Float](repeating: 0, count: count))
      XCTAssertEqual(result.frames, (count + 1279) / 1280)
      XCTAssertTrue(result.values.allSatisfy(\.isFinite))
    }
  }

  func testFrontendMatchesFirstAndFinalIndependentSnapshots() throws {
    let frontend = try WhistleFrontend(weights: weights())
    let (root, rows) = try fixtures()
    for row in rows {
      let pcm = try XCTUnwrap(row["pcm"] as? [String: String])
      let audio = try floats(root.appendingPathComponent(try XCTUnwrap(pcm["file"])))
      let devices = try XCTUnwrap(row["devices"] as? [String: Any])
      let gpu = try XCTUnwrap(devices["gpu"] as? [String: Any])
      let snapshots = try XCTUnwrap(gpu["snapshots"] as? [[String: Any]])
      for snapshot in snapshots {
        let samples = try XCTUnwrap(snapshot["samples"] as? Int)
        let entry = try XCTUnwrap(snapshot["stem"] as? [String: String])
        let gold = try floats(root.appendingPathComponent(try XCTUnwrap(entry["file"])))
        let actual = try frontend.forward(audio: Array(audio.prefix(samples)))
        XCTAssertEqual(actual.frames, snapshot["frames"] as? Int)
        // Empirical pilot gate: unchanged MLX CPU/GPU reaches 0.00270 here.
        XCTAssertLessThan(rmse(actual.values, gold), 0.005)
      }
    }
  }

  func testEncoderCacheBoundsLookaheadEOFAndSessionIsolation() throws {
    let model = try WhistleEncoder(weights: weights())
    let values = (0..<83 * 512).map { sinf(Float($0) * 0.013) }
    let full = try EncoderFeatures(values: values, frames: 83)
    let reference = model.makeSession()
    let whole = try reference.append(full, final: true).flatMap(\.values)
    let incremental = model.makeSession()
    var actual: [Float] = []
    for frames in [17, 34, 50, 66, 82, 83] {
      let snapshot = try EncoderFeatures(values: Array(values.prefix(frames * 512)), frames: frames)
      actual.append(
        contentsOf: try incremental.append(snapshot, final: frames == 83).flatMap(\.values))
      XCTAssertTrue(incremental.cachedKVFrames.allSatisfy { $0 <= 64 })
      XCTAssertEqual(incremental.convolutionFrames, Array(repeating: 4, count: 8))
    }
    XCTAssertEqual(actual, whole)
    XCTAssertEqual(incremental.projectedFrames, reference.projectedFrames)
    XCTAssertEqual(incremental.position, 83)
    XCTAssertTrue(incremental.closed)
    XCTAssertThrowsError(try incremental.append(full))
    let shrink = model.makeSession()
    _ = try shrink.append(full)
    XCTAssertThrowsError(
      try shrink.append(EncoderFeatures(values: Array(values.prefix(512)), frames: 1)))
    let emptyFlush = model.makeSession()
    let ready = try EncoderFeatures(values: Array(values.prefix(34 * 512)), frames: 34)
    _ = try emptyFlush.append(ready)
    let same = try EncoderFeatures(values: Array(values.prefix(16 * 512)), frames: 16)
    XCTAssertTrue(try emptyFlush.append(same, final: true).isEmpty)
    XCTAssertTrue(emptyFlush.closed)
    let again = try model.makeSession().append(full, final: true).flatMap(\.values)
    XCTAssertEqual(again, whole)
  }

  func testEncoderMatchesIndependentOracleOnFrozenStem() throws {
    let model = try WhistleEncoder(weights: weights())
    let (root, rows) = try fixtures()
    for row in rows {
      let devices = try XCTUnwrap(row["devices"] as? [String: Any])
      let gpu = try XCTUnwrap(devices["gpu"] as? [String: Any])
      let snapshots = try XCTUnwrap(gpu["snapshots"] as? [[String: Any]])
      let final = try XCTUnwrap(snapshots.last)
      let stemEntry = try XCTUnwrap(final["stem"] as? [String: String])
      let stem = try floats(root.appendingPathComponent(try XCTUnwrap(stemEntry["file"])))
      let encodedEntry = try XCTUnwrap(gpu["encoded"] as? [String: String])
      let gold = try floats(root.appendingPathComponent(try XCTUnwrap(encodedEntry["file"])))
      let session = model.makeSession()
      let actual = try session.append(
        EncoderFeatures(values: stem, frames: stem.count / 512), final: true
      ).flatMap(\.values)
      // Empirical pilot gate: unchanged MLX CPU/GPU encoder RMSE reaches 0.01883.
      XCTAssertLessThan(rmse(actual, gold), 0.05)
      XCTAssertEqual(session.position, gold.count / 512)
      XCTAssertEqual(session.projectedFrames, gpu["projected_frames"] as? Int)
    }
  }
}
