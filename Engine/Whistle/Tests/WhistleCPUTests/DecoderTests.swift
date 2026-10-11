import Foundation
import XCTest

@testable import WhistleCPU

final class DecoderTests: XCTestCase {
  func testRecoverySignalDistinguishesLoopFromOrdinaryRepetition() {
    XCTAssertFalse(WhistleDecoder.hasRepeatedTail([17, 17, 17]))
    XCTAssertFalse(WhistleDecoder.hasRepeatedTail([10, 11, 12, 13, 10, 11, 12, 13]))
    XCTAssertFalse(WhistleDecoder.hasRepeatedTail([10, 11, 12, 13, 10, 11, 12, 13, 10, 99]))
    XCTAssertTrue(WhistleDecoder.hasRepeatedTail([10, 11, 12, 13, 10, 11, 12, 13, 10, 11]))
  }
  func testFeaturesRejectBadShapesAndNonfiniteValues() {
    XCTAssertThrowsError(try EncoderFeatures(values: [], frames: 0))
    XCTAssertThrowsError(try EncoderFeatures(values: [0], frames: 1))
    XCTAssertThrowsError(
      try EncoderFeatures(values: [Float](repeating: .nan, count: 512), frames: 1))
    XCTAssertThrowsError(try EncoderFeatures(values: [], frames: Int.max))
  }

  func testFeatureFileRejectsPartialFloats() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0, 1, 2]).write(to: url)
    XCTAssertThrowsError(try EncoderFeatures(url: url))
  }

  func testFeatureLittleEndianRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    var data = Data()
    for _ in 0..<512 { data.append(contentsOf: [0, 0, 128, 63]) }
    try data.write(to: url)
    let feature = try EncoderFeatures(url: url)
    XCTAssertEqual(feature.frames, 1)
    XCTAssertEqual(feature.values, [Float](repeating: 1, count: 512))
  }

  func testRealArchiveEffectiveWeightFixtures() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["WHISTLE_WEIGHTS"], let root = env["WHISTLE_FIXTURES"] else {
      throw XCTSkip("Set archive and fixture paths for effective-weight parity")
    }
    let weights = try WhistleWeights(url: URL(fileURLWithPath: path))
    let url = URL(fileURLWithPath: root).appendingPathComponent("linear.json")
    let oracleDecoder = JSONDecoder()
    oracleDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let cases = try oracleDecoder.decode(LinearOracle.self, from: Data(contentsOf: url)).cases
    XCTAssertEqual(cases.count, 5)
    for fixture in cases {
      let tensor = try XCTUnwrap(weights.tensors[fixture.name])
      let actual: [Float]
      if let row = fixture.row {
        actual = try tensor.row(row)
      } else {
        let range = fixture.outputRange.map { $0[0]..<$0[1] }
        actual = try tensor.linear(
          try XCTUnwrap(fixture.input), inputRows: try XCTUnwrap(fixture.inputRows),
          outputRows: range)
      }
      XCTAssertEqual(actual.count, fixture.expected.count)
      for (a, b) in zip(actual, fixture.expected) {
        XCTAssertEqual(a, b, accuracy: 1e-4, fixture.name)
      }
    }
  }

  func testRealArchiveDecoderParity() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["WHISTLE_WEIGHTS"], let root = env["WHISTLE_FIXTURES"] else {
      throw XCTSkip("Set WHISTLE_WEIGHTS and WHISTLE_FIXTURES for real MLX decoder parity")
    }
    let weights = try WhistleWeights(url: URL(fileURLWithPath: path))
    let decoder = try WhistleDecoder(weights: weights)
    let directory = URL(fileURLWithPath: root)
    let oracleDecoder = JSONDecoder()
    oracleDecoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try oracleDecoder.decode(
      Oracle.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    XCTAssertEqual(manifest.rows.count, 4)
    for row in manifest.rows {
      let features = try EncoderFeatures(url: directory.appendingPathComponent(row.features))
      XCTAssertThrowsError(try decoder.logits(prefix: [], features: features))
      XCTAssertThrowsError(try decoder.logits(prefix: [-1], features: features))
      XCTAssertThrowsError(try decoder.decode(features: features, maxTokens: 319))
      for fixture in row.logitFixtures {
        let logits = try decoder.logits(prefix: fixture.prefix, features: features)
        let bytes = try Data(contentsOf: directory.appendingPathComponent(fixture.file))
        let gold: [Float] = bytes.withUnsafeBytes { raw in
          stride(from: 0, to: raw.count, by: 4).map {
            Float(
              bitPattern: UInt32(
                littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
          }
        }
        XCTAssertEqual(logits.count, 8192)
        XCTAssertEqual(gold.count, 8192)
        let rmse = sqrt(zip(logits, gold).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / 8192)
        // Unmodified MLX CPU vs this GPU oracle reaches 0.269 RMSE (see report).
        // Keep exact token/argmax checks: this is NOT bitwise floating-point parity.
        XCTAssertLessThan(
          rmse, 0.30, "\(row.filename) \(fixture.prefix.count)-token prefix logit error")
        XCTAssertEqual(logits.indices.max { logits[$0] < logits[$1] }, fixture.argmax, row.filename)
      }
      let result = try decoder.decode(features: features)
      XCTAssertTrue(result.endedWithEOS, row.filename)
      XCTAssertEqual(result.ids, row.ids, row.filename)
      XCTAssertEqual(result.text, row.hypothesis, row.filename)
      // A fresh second draft must not inherit causal token caches from the first.
      let again = try decoder.logits(prefix: [2, 8192], features: features)
      XCTAssertEqual(again.indices.max { again[$0] < again[$1] }, row.logitFixtures[0].argmax)
    }
  }
}

private struct Oracle: Decodable {
  let rows: [Row]
  struct Row: Decodable {
    let filename: String
    let features: String
    let hypothesis: String
    let ids: [Int]
    let logitFixtures: [Fixture]
  }
  struct Fixture: Decodable {
    let prefix: [Int]
    let file: String
    let argmax: Int
  }
}

private struct LinearOracle: Decodable {
  let cases: [Case]
  struct Case: Decodable {
    let name: String
    let row: Int?
    let input: [Float]?
    let inputRows: Int?
    let outputRange: [Int]?
    let expected: [Float]
  }
}
