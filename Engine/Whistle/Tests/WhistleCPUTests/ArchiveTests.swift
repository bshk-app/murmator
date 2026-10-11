import Foundation
import XCTest

@testable import WhistleCPU

final class ArchiveTests: XCTestCase {
  private let codebook: [Float] =
    [-0.31, -0.07, 0.04, 0.22] + Array(repeating: 0, count: 8)
    + (0..<16).map { Float($0 * $0 - 40) / 300 }

  private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private func blob(
    dtype: UInt8, shape: [Int], payload: Data, bits: UInt32 = 0,
    group: UInt32 = 0
  ) -> Data {
    var result = Data()
    var header = [UInt32](repeating: 0, count: 48)
    header[0] = 0x05E1_2A84
    header[1] = 1
    header[2] = 28
    for v in header { append(v, to: &result) }
    append(Float(100000).bitPattern, to: &result)
    for v in codebook { append(v.bitPattern, to: &result) }
    result.append(dtype)
    result.append(UInt8(shape.count))
    append(UInt16(0), to: &result)
    for i in 0..<4 { append(UInt32(i < shape.count ? shape[i] : 0), to: &result) }
    append(UInt64(384), to: &result)
    append(UInt64(payload.count), to: &result)
    append(group, to: &result)
    append(bits, to: &result)
    result.append(Data(repeating: 0, count: 384 - result.count))
    result.append(payload)
    return result
  }

  private func cq(rows: Int, width: Int, bits: Int, shape: [Int]? = nil) throws -> PackedTensor {
    let padded = (width + 127) / 128 * 128
    var payload = Data()
    for row in 0..<rows {
      for start in stride(from: 0, to: padded, by: 8) {
        var word: UInt32 = 0
        for k in 0..<8 { word |= UInt32((row * 3 + start + k) % (1 << bits)) << (k * bits) }
        for b in 0..<bits { payload.append(UInt8(truncatingIfNeeded: word >> (8 * b))) }
      }
    }
    for row in 0..<rows {
      for g in 0..<(padded / 128) {
        append(Float16(Float(row + g + 1) / 8).bitPattern, to: &payload)
      }
    }
    return try WhistleArchive(
      data: blob(
        dtype: 3, shape: shape ?? [rows, width],
        payload: payload, bits: UInt32(bits), group: 128)
    ).records[0]
  }

  // Independent dense Sylvester formula: H[i,j] = (-1)^popcount(i & j)/sqrt(128).
  private func expectedRow(_ row: Int, width: Int, bits: Int) -> [Float] {
    let cb = bits == 2 ? Array(codebook[0..<4]) : Array(codebook[12..<28])
    return (0..<width).map { column in
      let group = column / 128
      var sum: Float = 0
      for k in 0..<128 {
        let idx = (row * 3 + group * 128 + k) % (1 << bits)
        let sign: Float = (k & (column % 128)).nonzeroBitCount % 2 == 0 ? 1 : -1
        sum += sign * cb[idx] * Float(row + group + 1) / 8
      }
      return sum / sqrt(128)
    }
  }

  private func assertNear(
    _ actual: [Float], _ expected: [Float], accuracy: Float = 0.0002,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (a, b) in zip(actual, expected) {
      XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
    }
  }

  func testCQRowUsesLSBCodebookNormAndNormalizedSylvester() throws {
    for bits in [2, 4] {
      let tensor = try cq(rows: 6, width: 193, bits: bits, shape: [2, 3, 193])
      XCTAssertEqual(tensor.shape, [2, 3, 193])
      XCTAssertTrue(tensor.isQuantized)
      XCTAssertThrowsError(try tensor.values())
      assertNear(try tensor.row(4), expectedRow(4, width: 193, bits: bits))
      XCTAssertThrowsError(try tensor.row(-1))
      XCTAssertThrowsError(try tensor.row(6))
    }
  }

  func testCQLinearBatchesRangesAndCrosses64RowTileBoundary() throws {
    for bits in [2, 4] {
      let width = 193
      let tensor = try cq(rows: 70, width: width, bits: bits)
      let input = (0..<(width * 2)).map { Float(($0 * 7) % 23 - 11) / 13 }
      for range in [0..<70, 3..<69, 12..<16, 16..<32] {
        var expected: [Float] = []
        for n in 0..<2 {
          for r in range {
            let weight = expectedRow(r, width: width, bits: bits)
            expected.append(
              (0..<width).reduce(Float(0)) { $0 + input[n * width + $1] * weight[$1] })
          }
        }
        assertNear(
          try tensor.linear(input, inputRows: 2, outputRows: range), expected, accuracy: 0.001)
        assertNear(
          try tensor.linear(Array(input.prefix(width)), outputRows: range),
          Array(expected.prefix(range.count)), accuracy: 0.001)
      }
      let x = Array(input.prefix(width))
      let weight = expectedRow(4, width: width, bits: bits)
      assertNear(
        try tensor.linear(x, outputRows: 4..<5), [zip(x, weight).reduce(0) { $0 + $1.0 * $1.1 }])
      XCTAssertEqual(try tensor.linear(x, outputRows: 0..<0), [])
      XCTAssertThrowsError(try tensor.linear(x, inputRows: 0))
      XCTAssertThrowsError(try tensor.linear(x, inputRows: 2))
      XCTAssertThrowsError(try tensor.linear(x, outputRows: -1..<2))
      XCTAssertThrowsError(try tensor.linear(x, outputRows: 69..<71))
      XCTAssertThrowsError(try tensor.linear(x, inputRows: Int.max))
    }
  }

  func testFP16AndFP32ValuesRowsAndStoredOrientation() throws {
    let values: [Float] = [1.25, -2, 3, 4, 0.5, -6]
    for dtype in [UInt8(1), UInt8(2)] {
      var payload = Data()
      for value in values {
        if dtype == 1 {
          append(Float16(value).bitPattern, to: &payload)
        } else {
          append(value.bitPattern, to: &payload)
        }
      }
      let tensor = try WhistleArchive(data: blob(dtype: dtype, shape: [2, 3], payload: payload))
        .records[0]
      XCTAssertFalse(tensor.isQuantized)
      XCTAssertEqual(try tensor.values(), values)
      XCTAssertEqual(try tensor.row(1), [4, 0.5, -6])
      assertNear(try tensor.linear([1, 2, 3]), [6.25, -13])
      assertNear(
        try tensor.linear([1, 2, 3, 2, 1, -1], inputRows: 2, outputRows: 1..<2), [-13, 14.5])
      XCTAssertThrowsError(try tensor.row(2))
    }
  }

  func testDirectoryRejectsTruncationUnknownFormatsAndInvalidExtents() throws {
    var payload = Data()
    append(Float16(1).bitPattern, to: &payload)
    let valid = blob(dtype: 1, shape: [1], payload: payload)
    for length in [0, 195, 307, 351, 383, 385] {
      XCTAssertThrowsError(try WhistleArchive(data: Data(valid.prefix(length))))
    }
    // Fixed little-endian offsets inside the single record; mutate independently of the reader.
    for (offset, bytes) in [
      (0, [UInt8(0)]), (308, [9]), (309, [5]), (312, [0, 0, 0, 0]),
      (328, [0, 0, 0, 0, 0, 0, 0, 0]),
      (328, [255, 255, 255, 255, 255, 255, 255, 255]),
      (336, [3]), (344, [128]), (348, [2]),
    ] {
      var bad = valid
      bad.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
      XCTAssertThrowsError(try WhistleArchive(data: bad), "offset \(offset)")
    }
    for bits in [UInt32(0), 1, 3, 5, 8] {
      XCTAssertThrowsError(
        try WhistleArchive(
          data: blob(
            dtype: 3, shape: [1, 128],
            payload: Data(repeating: 0, count: 66), bits: bits, group: 128)))
    }
    XCTAssertThrowsError(
      try WhistleArchive(
        data: blob(
          dtype: 3, shape: [1, 128],
          payload: Data(repeating: 0, count: 66), bits: 4, group: 64)))
    XCTAssertThrowsError(
      try WhistleArchive(
        data: blob(
          dtype: 3, shape: [1, 128],
          payload: Data(repeating: 0, count: 65), bits: 4, group: 128)))
    XCTAssertThrowsError(
      try WhistleArchive(
        data: blob(
          dtype: 2,
          shape: [Int(UInt32.max), Int(UInt32.max), Int(UInt32.max)], payload: payload)))
    var trailing = valid
    trailing.append(0)
    XCTAssertThrowsError(try WhistleArchive(data: trailing))
    // The public loader must reject a generic archive lacking the deployed geometry.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try valid.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertThrowsError(try WhistleWeights(url: url))
  }

  private func tokenizerBlob(dummy: Bool, pieces: [(String, UInt8)]) -> Data {
    var data = Data()
    append(UInt32(pieces.count), to: &data)
    for _ in 0..<4 { append(UInt32(0), to: &data) }
    data.append(dummy ? 1 : 0)
    data.append(1)
    append(UInt16(0), to: &data)
    for (text, type) in pieces {
      append(Float(0).bitPattern, to: &data)
      data.append(type)
      append(UInt16(text.utf8.count), to: &data)
      data.append(contentsOf: text.utf8)
    }
    return data
  }

  func testTokenizerByteFallbackControlUnknownSpacesAndReplacement() throws {
    let pieces: [(String, UInt8)] = [
      ("▁hello", 0), ("▁世界", 0), ("<s>", 2), ("<unk>", 1),
      ("<0xC3>", 4), ("<0xA9>", 4), ("<marker>", 3), ("▁", 0),
    ]
    for dummy in [true, false] {
      let data = tokenizerBlob(dummy: dummy, pieces: pieces)
      let tk = try WhistleTokenizer(data: data)
      XCTAssertEqual(
        try tk.decode([2, 3, 0, 1, 4, 5, 6]), (dummy ? "" : " ") + "hello 世界é<marker>")
      XCTAssertEqual(try tk.decode([7, 7, 0]), dummy ? "  hello" : "   hello")
      XCTAssertEqual(try tk.decode([4]), "�")
      XCTAssertEqual(try tk.decode([]), "")
      XCTAssertThrowsError(try tk.decode([-1]))
      XCTAssertThrowsError(try tk.decode([8]))
      for length in [0, 23, data.count - 1] {
        XCTAssertThrowsError(try WhistleTokenizer(data: Data(data.prefix(length))))
      }
      var bad = data
      bad.append(0)
      XCTAssertThrowsError(try WhistleTokenizer(data: bad))
    }
    for badPiece in [("<0xGG>", UInt8(4)), ("x", 4), ("x", 5)] {
      XCTAssertThrowsError(
        try WhistleTokenizer(data: tokenizerBlob(dummy: false, pieces: [badPiece])))
    }
    var badUTF8 = tokenizerBlob(dummy: false, pieces: [("x", 0)])
    badUTF8[badUTF8.count - 1] = 255
    XCTAssertThrowsError(try WhistleTokenizer(data: badUTF8))
  }

  func testDeployedArchiveOptIn() throws {
    guard let path = ProcessInfo.processInfo.environment["WHISTLE_WEIGHTS"] else {
      throw XCTSkip("Set WHISTLE_WEIGHTS for deployed archive checks")
    }
    let weights = try WhistleWeights(url: URL(fileURLWithPath: path))
    XCTAssertEqual(
      weights.mappedBytes,
      try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped).count)
    XCTAssertEqual(weights.tensors.count, 679)
    XCTAssertEqual(weights.tensors["embedding/embedding"]?.shape, [8199, 512])
    XCTAssertEqual(weights.tensors["engrams_1/embedding"]?.shape, [73728, 128])
    XCTAssertEqual(weights.tensors["stack/mhc_phi_pre"]?.shape, [32, 2048])
    XCTAssertEqual(weights.tensors["stack/mhc_phi_res"]?.shape, [128, 2048])
    XCTAssertEqual(weights.tensors["stack/mhc_a_pre"]?.shape, [8])
    XCTAssertEqual(weights.tensors["decoder/7/cross_attn/k_proj/kernel"]?.shape, [384, 512])
    for (name, range) in [
      ("embedding/embedding", 0..<8192), ("stack/mhc_phi_pre", 12..<16),
      ("stack/mhc_phi_res", 48..<64), ("engrams_1/embedding", 18432..<18436),
    ] {
      let tensor = try XCTUnwrap(weights.tensors[name])
      XCTAssertThrowsError(try tensor.values())
      let input = (0..<tensor.shape.last!).map { Float($0 % 17 - 8) / 9 }
      let actual = try tensor.linear(input, outputRows: range)
      for index in [range.lowerBound, range.upperBound - 1] {
        let expected = zip(input, try tensor.row(index)).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertEqual(
          actual[index - range.lowerBound], expected, accuracy: max(0.001, abs(expected) * 0.0001))
      }
    }
    XCTAssertEqual(try weights.tokenizer.decode([]), "")
  }
}
