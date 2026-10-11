import Accelerate
import Foundation

public enum WhistleArchiveError: Error, CustomStringConvertible {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let message): return "Whistle archive: \(message)"
    }
  }
}

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw WhistleArchiveError.invalid(message) }
}

private func product(_ a: Int, _ b: Int) throws -> Int {
  let (value, overflow) = a.multipliedReportingOverflow(by: b)
  try require(!overflow && value >= 0, "size overflow")
  return value
}

private func aligned(_ value: Int) throws -> Int {
  let (sum, overflow) = value.addingReportingOverflow(63)
  try require(!overflow, "alignment overflow")
  return sum & ~63
}

private struct Bytes {
  let data: Data
  var cursor = 0
  let end: Int

  init(_ data: Data, start: Int = 0, end: Int? = nil) {
    self.data = data
    self.cursor = start
    self.end = end ?? data.count
  }

  mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
    let size = MemoryLayout<T>.size
    try require(cursor >= 0 && cursor <= end && size <= end - cursor, "truncated data")
    let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
    cursor += size
    return T(littleEndian: value)
  }

  mutating func float() throws -> Float { Float(bitPattern: try integer(UInt32.self)) }

  mutating func string(length: Int) throws -> String {
    try require(length >= 0 && cursor <= end && length <= end - cursor, "truncated piece")
    let bytes = data[cursor..<(cursor + length)]
    guard let value = String(data: bytes, encoding: .utf8) else {
      throw WhistleArchiveError.invalid("non-UTF8 tokenizer piece")
    }
    cursor += length
    return value
  }
}

/// Retains mapped storage, not decoded weights. CQ row() is the only weight-space expansion.
public final class PackedTensor {
  public let shape: [Int]
  public let isQuantized: Bool
  fileprivate let dtype: UInt8
  fileprivate let offset: Int
  fileprivate let nbytes: Int
  private let data: Data
  private let bits: Int
  private let codebook: [Float]
  private let rows: Int
  private let width: Int
  private let paddedWidth: Int
  private let packedBytes: Int

  fileprivate init(
    data: Data, dtype: UInt8, shape: [Int], offset: Int, nbytes: Int,
    group: Int, bits: Int, codebook: [Float]
  ) throws {
    try require((1...4).contains(dtype), "unknown dtype \(dtype)")
    try require(
      offset >= 0 && offset <= data.count && nbytes <= data.count - offset,
      "tensor outside file")
    try require(shape.count <= 4 && shape.allSatisfy { $0 > 0 }, "invalid shape")
    self.data = data
    self.dtype = dtype
    self.shape = shape
    self.isQuantized = dtype == 3
    self.offset = offset
    self.nbytes = nbytes
    self.bits = bits
    if dtype == 4 {
      try require(shape.isEmpty && group == 0 && bits == 0, "invalid RAW geometry")
      rows = 0
      width = 0
      paddedWidth = 0
      packedBytes = 0
      self.codebook = []
      return
    }
    try require(!shape.isEmpty, "empty numeric shape")
    width = shape.last!
    rows = try shape.dropLast().reduce(1) { try product($0, $1) }
    let elements = try product(rows, width)
    if dtype == 3 {
      try require(
        shape.count >= 2 && group == 128 && (bits == 2 || bits == 4),
        "unsupported CQ width/group")
      let (sum, overflow) = width.addingReportingOverflow(127)
      try require(!overflow, "CQ padding overflow")
      paddedWidth = sum / 128 * 128
      packedBytes = try product(rows, paddedWidth / 8 * bits)
      let normBytes = try product(try product(rows, paddedWidth / 128), 2)
      try require(
        packedBytes <= nbytes && normBytes == nbytes - packedBytes,
        "CQ payload geometry mismatch")
      self.codebook = Array(codebook[bits == 2 ? 0..<4 : 12..<28])
    } else {
      try require(group == 0 && bits == 0, "unexpected quantization metadata")
      try require(
        try product(elements, dtype == 1 ? 2 : 4) == nbytes,
        "float payload geometry mismatch")
      paddedWidth = width
      packedBytes = 0
      self.codebook = []
    }
  }

  public func values() throws -> [Float] {
    try require(dtype == 1 || dtype == 2, "values() only accepts FP16/FP32; use CQ row/linear")
    return data.withUnsafeBytes { raw in
      (0..<(rows * width)).map { scalar(raw, $0) }
    }
  }

  private func scalar(_ raw: UnsafeRawBufferPointer, _ index: Int) -> Float {
    if dtype == 1 {
      let word = raw.loadUnaligned(fromByteOffset: offset + index * 2, as: UInt16.self)
      return Float(Float16(bitPattern: UInt16(littleEndian: word)))
    }
    let word = raw.loadUnaligned(fromByteOffset: offset + index * 4, as: UInt32.self)
    return Float(bitPattern: UInt32(littleEndian: word))
  }

  /// Decode codebook * norm in rotated space, one flattened leading row at a time.
  private func unpack(
    _ raw: UnsafeRawBufferPointer, row: Int, into output: inout [Float], at base: Int
  ) {
    let rowBytes = paddedWidth / 8 * bits
    let mask = (1 << bits) - 1
    for group in 0..<(paddedWidth / 128) {
      let normOffset = offset + packedBytes + (row * (paddedWidth / 128) + group) * 2
      let norm = Float(
        Float16(
          bitPattern: UInt16(
            littleEndian:
              raw.loadUnaligned(fromByteOffset: normOffset, as: UInt16.self))))
      for column in (group * 128)..<((group + 1) * 128) {
        let bit = column * bits
        let byte = Int(raw[offset + row * rowBytes + bit / 8])
        let index = (byte >> (bit % 8)) & mask
        output[base + column] = codebook[index] * norm
      }
    }
  }

  // Sylvester order, orthonormal: exactly numpy.block([[H,H],[H,-H]]) / sqrt(128).
  private static func rotate(_ vector: inout [Float], base: Int) {
    var stride = 1
    while stride < 128 {
      for block in Swift.stride(from: 0, to: 128, by: stride * 2) {
        for i in 0..<stride {
          let a = base + block + i
          let b = a + stride
          let x = vector[a]
          let y = vector[b]
          vector[a] = x + y
          vector[b] = x - y
        }
      }
      stride *= 2
    }
    let scale: Float = 1 / sqrt(128)
    for i in base..<(base + 128) { vector[i] *= scale }
  }

  public func row(_ index: Int) throws -> [Float] {
    try require(dtype != 4 && index >= 0 && index < rows, "row outside tensor")
    if !isQuantized {
      return data.withUnsafeBytes { raw in
        (0..<width).map { scalar(raw, index * width + $0) }
      }
    }
    var result = [Float](repeating: 0, count: paddedWidth)
    data.withUnsafeBytes { unpack($0, row: index, into: &result, at: 0) }
    for base in Swift.stride(from: 0, to: paddedWidth, by: 128) { Self.rotate(&result, base: base) }
    if width < paddedWidth { result.removeLast(paddedWidth - width) }
    return result
  }

  /// Stored [out,in], row-major N x in -> N x selected-out. Scratch weights <= 64 rows.
  public func linear(
    _ input: [Float], inputRows: Int = 1,
    outputRows: Range<Int>? = nil
  ) throws -> [Float] {
    try require(dtype != 4 && inputRows > 0, "invalid linear input")
    try require(try product(inputRows, width) == input.count, "linear input size mismatch")
    let range = outputRows ?? 0..<rows
    try require(range.lowerBound >= 0 && range.upperBound <= rows, "output range outside tensor")
    try require(inputRows <= Int(Int32.max) && paddedWidth <= Int(Int32.max), "BLAS size overflow")
    let selected = range.count
    try require(selected <= Int(Int32.max), "BLAS output size overflow")
    var result = [Float](repeating: 0, count: try product(inputRows, selected))
    if selected == 0 { return result }
    var rotated: [Float]
    if isQuantized {
      rotated = [Float](repeating: 0, count: try product(inputRows, paddedWidth))
      for n in 0..<inputRows {
        for i in 0..<width { rotated[n * paddedWidth + i] = input[n * width + i] }
        for base in Swift.stride(from: n * paddedWidth, to: (n + 1) * paddedWidth, by: 128) {
          Self.rotate(&rotated, base: base)
        }
      }
    } else {
      rotated = input
    }
    if isQuantized && inputRows == 1 {
      // Decode eight CQ codes directly into SIMD lanes. Single-token drafts do not
      // need a temporary dense weight tile or one BLAS dispatch per 64 output rows.
      let rowBytes = paddedWidth / 8 * bits
      let groups = paddedWidth / 128
      let mask = UInt32((1 << bits) - 1)
      data.withUnsafeBytes { raw in
        rotated.withUnsafeBufferPointer { x in
          let xp = UnsafeRawPointer(x.baseAddress!)
          for row in range {
            var sum = SIMD8<Float>(repeating: 0)
            for group in 0..<groups {
              let normOffset = offset + packedBytes + (row * groups + group) * 2
              let norm = Float(
                Float16(
                  bitPattern: UInt16(
                    littleEndian: raw.loadUnaligned(fromByteOffset: normOffset, as: UInt16.self))))
              for column in Swift.stride(from: group * 128, to: (group + 1) * 128, by: 8) {
                let source = offset + row * rowBytes + column * bits / 8
                let word: UInt32
                if bits == 4 {
                  word = UInt32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: source, as: UInt32.self))
                } else {
                  word = UInt32(
                    UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: source, as: UInt16.self))
                  )
                }
                let codes = SIMD8<Float>(
                  codebook[Int(word & mask)], codebook[Int((word >> bits) & mask)],
                  codebook[Int((word >> (2 * bits)) & mask)],
                  codebook[Int((word >> (3 * bits)) & mask)],
                  codebook[Int((word >> (4 * bits)) & mask)],
                  codebook[Int((word >> (5 * bits)) & mask)],
                  codebook[Int((word >> (6 * bits)) & mask)],
                  codebook[Int((word >> (7 * bits)) & mask)])
                let inputVector = xp.loadUnaligned(
                  fromByteOffset: column * 4, as: SIMD8<Float>.self)
                sum += (codes * SIMD8<Float>(repeating: norm)) * inputVector
              }
            }
            result[row - range.lowerBound] = sum.sum()
          }
        }
      }
      return result
    }
    // No persistent decoded cache; even very large embeddings only unpack the requested tile.
    for start in Swift.stride(from: range.lowerBound, to: range.upperBound, by: 64) {
      let count = min(64, range.upperBound - start)
      var tile = [Float](repeating: 0, count: try product(count, paddedWidth))
      data.withUnsafeBytes { raw in
        for r in 0..<count {
          if isQuantized {
            unpack(raw, row: start + r, into: &tile, at: r * paddedWidth)
          } else {
            for c in 0..<width { tile[r * width + c] = scalar(raw, (start + r) * width + c) }
          }
        }
      }
      rotated.withUnsafeBufferPointer { x in
        tile.withUnsafeBufferPointer { w in
          result.withUnsafeMutableBufferPointer { y in
            cblas_sgemm(
              CblasRowMajor, CblasNoTrans, CblasTrans,
              Int32(inputRows), Int32(count), Int32(paddedWidth), 1,
              x.baseAddress!, Int32(paddedWidth), w.baseAddress!, Int32(paddedWidth),
              0, y.baseAddress!.advanced(by: start - range.lowerBound), Int32(selected))
          }
        }
      }
    }
    return result
  }
}

/// Internal format reader also used by synthetic tests, independent of Whistle's fixed geometry.
struct WhistleArchive {
  let header: [UInt32]
  let records: [PackedTensor]

  init(data: Data) throws {
    var reader = Bytes(data)
    var h: [UInt32] = []
    for _ in 0..<48 { h.append(try reader.integer(UInt32.self)) }
    let theta = try reader.float()
    try require(h[0] == 0x05E1_2A84 && h[2] == 28, "bad tag/codebook length")
    try require(theta.isFinite && theta > 0, "invalid RoPE theta")
    let count = Int(h[1])
    try require(count > 0 && count <= max(0, (data.count - 308) / 44), "truncated directory")
    var codebook: [Float] = []
    for _ in 0..<28 {
      let value = try reader.float()
      try require(value.isFinite, "invalid codebook")
      codebook.append(value)
    }
    var previousEnd = 308 + count * 44
    var tensors: [PackedTensor] = []
    for _ in 0..<count {
      let dtype = try reader.integer(UInt8.self)
      let ndim = Int(try reader.integer(UInt8.self))
      let pad = try reader.integer(UInt16.self)
      try require(ndim <= 4 && pad == 0, "invalid directory rank/padding")
      var shape: [Int] = []
      for axis in 0..<4 {
        let dimension = Int(try reader.integer(UInt32.self))
        if axis < ndim {
          shape.append(dimension)
        } else {
          try require(dimension == 0, "nonzero unused dimension")
        }
      }
      let offset64 = try reader.integer(UInt64.self)
      let size64 = try reader.integer(UInt64.self)
      let group = Int(try reader.integer(UInt32.self))
      let bits = Int(try reader.integer(UInt32.self))
      try require(offset64 <= UInt64(data.count) && size64 <= UInt64(data.count), "invalid extent")
      let offset = Int(offset64)
      let size = Int(size64)
      try require(offset == aligned(previousEnd), "nonsequential or unaligned tensor extent")
      let tensor = try PackedTensor(
        data: data, dtype: dtype, shape: shape, offset: offset,
        nbytes: size, group: group, bits: bits, codebook: codebook)
      tensors.append(tensor)
      previousEnd = offset + size
    }
    try require(previousEnd == data.count, "trailing or truncated payload")
    header = h
    records = tensors
  }
}

public struct WhistleTokenizer {
  private struct Piece {
    let text: String
    let type: UInt8
    let byte: UInt8?
  }
  private let pieces: [Piece]
  private let addDummy: Bool
  fileprivate var count: Int { pieces.count }

  init(data: Data, offset: Int = 0, length: Int? = nil) throws {
    let length = length ?? data.count
    try require(
      offset >= 0 && offset <= data.count && length >= 0 && length <= data.count - offset,
      "tokenizer extent")
    var reader = Bytes(data, start: offset, end: offset + length)
    let count = Int(try reader.integer(UInt32.self))
    var special: [UInt32] = []
    for _ in 0..<4 { special.append(try reader.integer(UInt32.self)) }
    let dummy = try reader.integer(UInt8.self)
    let fallback = try reader.integer(UInt8.self)
    let padding = try reader.integer(UInt16.self)
    try require(
      count > 0 && count <= (reader.end - reader.cursor) / 7,
      "invalid tokenizer piece count")
    try require(
      special.allSatisfy { $0 < count } && dummy <= 1 && fallback <= 1 && padding == 0,
      "invalid tokenizer header")
    var parsed: [Piece] = []
    for _ in 0..<count {
      _ = try reader.float()  // Scores are not needed by decode.
      let type = try reader.integer(UInt8.self)
      let size = Int(try reader.integer(UInt16.self))
      try require(type <= 4, "unknown tokenizer piece type")
      let text = try reader.string(length: size)
      var byte: UInt8?
      if type == 4 {
        let chars = Array(text.utf8)
        try require(
          chars.count == 6 && chars[0] == 60 && chars[1] == 48 && chars[2] == 120
            && chars[5] == 62, "invalid BYTE piece")
        byte = UInt8(String(decoding: chars[3..<5], as: UTF8.self), radix: 16)
        try require(byte != nil, "invalid BYTE hex")
      }
      parsed.append(Piece(text: text, type: type, byte: byte))
    }
    try require(reader.cursor == reader.end, "trailing tokenizer bytes")
    pieces = parsed
    addDummy = dummy == 1
  }

  public func decode(_ ids: [Int]) throws -> String {
    var bytes: [UInt8] = []
    for id in ids {
      try require(id >= 0 && id < pieces.count, "token id outside vocabulary")
      let piece = pieces[id]
      if piece.type == 4 {
        bytes.append(piece.byte!)
      } else if piece.type != 1 && piece.type != 2 {
        bytes.append(contentsOf: piece.text.utf8)
      }
    }
    var text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "▁", with: " ")
    if addDummy && text.hasPrefix(" ") { text.removeFirst() }
    return text
  }
}

public final class WhistleWeights {
  public let tensors: [String: PackedTensor]
  public let tokenizer: WhistleTokenizer
  public let mappedBytes: Int

  public init(url: URL) throws {
    // .alwaysMapped guarantees no eager file copy. Every PackedTensor retains this same Data.
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    let archive = try WhistleArchive(data: data)
    let h = archive.header
    let fixed: [Int: UInt32] = [
      1: 681, 5: 8199, 7: 512, 8: 8, 9: 2, 10: 8, 11: 48,
      12: 64, 14: 512, 15: 4, 19: 3, 20: 18432, 21: 128,
      22: 4, 23: 4, 24: 3, 26: 2, 27: 2, 28: 3, 31: 2, 32: 3, 33: 7,
    ]
    try require(
      fixed.allSatisfy { h[$0.key] == $0.value } && (h[6] == 0 || h[6] == 8192),
      "unsupported Whistle geometry")
    let records = archive.records
    try require(
      records.dropLast().allSatisfy { $0.dtype != 4 } && records.last?.dtype == 4,
      "tokenizer must be the final and only RAW record")
    var named: [String: PackedTensor] = [:]
    var cursor = 0
    func take(_ name: String, _ shape: [Int], quantized: Bool = false) throws {
      try require(cursor < records.count, "missing tensor \(name)")
      let tensor = records[cursor]
      try require(
        tensor.shape == shape && tensor.isQuantized == quantized && tensor.dtype != 4,
        "tensor contract mismatch: \(name)")
      named[name] = tensor
      cursor += 1
    }
    func mhc(_ prefix: String) throws {
      for name in ["a_pre", "a_post", "a_res"] { try take(prefix + "/mhc_" + name, [8]) }
      for name in ["b_pre", "b_post"] { try take(prefix + "/mhc_" + name, [8, 4]) }
      try take(prefix + "/mhc_b_res", [8, 4, 4])
      try take(prefix + "/mhc_phi_pre", [32, 2048], quantized: true)
      try take(prefix + "/mhc_phi_post", [32, 2048], quantized: true)
      try take(prefix + "/mhc_phi_res", [128, 2048], quantized: true)
    }
    try take("embedding/embedding", [8199, 512], quantized: true)
    for layer in 0..<8 {
      let p = "decoder/\(layer)/"
      try take(p + "ZCRMSNorm_0/scale", [512])
      for (name, out) in [("q_proj", 384), ("k_proj", 96), ("v_proj", 128)] {
        try take(p + "self_attn/" + name + "/kernel", [out, 512], quantized: true)
      }
      for (name, out) in [("q_taps", 384), ("k_taps", 96), ("v_taps", 128)] {
        try take(p + "self_attn/" + name, [3, out])
      }
      for name in ["q_norm", "k_norm"] { try take(p + "self_attn/" + name + "/scale", [48]) }
      for name in ["gate_proj", "out_proj"] {
        try take(p + "self_attn/" + name + "/kernel", [512, 512], quantized: true)
      }
      try take(p + "post_attn_norm/scale", [512])
      try take(p + "attn_gate", [1])
      try take(p + "pre_hada_norm/scale", [512])
      for name in ["d1", "d2", "b2", "d3", "d4"] { try take(p + "hadamard_mlp/" + name, [512]) }
      for n in 1...3 {
        try take(p + "hadamard_mlp/w\(n)a", [16, 16])
        try take(p + "hadamard_mlp/w\(n)b", [32, 32])
      }
      try take(p + "hadamard_mlp/cond_v", [512, 8])
      try take(p + "hadamard_mlp/cond_u", [8, 512])
    }
    try mhc("stack")
    try take("hada_p1", [512])
    try take("hada_p2", [512])
    for site in 0..<2 {
      let p = "engrams_\(site)/"
      try take(p + "embedding", [73728, 128], quantized: true)
      for name in ["key_proj", "value_proj"] {
        try take(p + name + "/kernel", [512, 512], quantized: true)
      }
      try take(p + "taps", [4, 512])
    }
    try take("stack/final_norm/scale", [512])
    let manifest = records[cursor]
    cursor += 1
    try require(manifest.shape == [13] && manifest.dtype == 2, "invalid speech manifest")
    try require(
      try manifest.values() == [3246, 1, 8192, 8, 4, 9, 128, 3, 80, 16000, 512, 400, 160],
      "unsupported speech manifest")
    for layer in 0..<8 {
      let p = "decoder/\(layer)/"
      try take(p + "cross_norm/scale", [512])
      for (name, out) in [
        ("q_proj", 384), ("k_proj", 384), ("v_proj", 512),
        ("gate_proj", 512), ("out_proj", 512),
      ] {
        try take(p + "cross_attn/" + name + "/kernel", [out, 512], quantized: true)
      }
      for name in ["q_norm", "k_norm"] { try take(p + "cross_attn/" + name + "/scale", [48]) }
      try take(p + "post_cross_norm/scale", [512])
      try take(p + "cross_gate", [1])
    }
    try take("pe_gate", [1])
    // Positional names verified against every layer of the pinned open checkpoint.
    try require(cursor == 319, "unexpected encoder start")
    for layer in 0..<8 {
      let p = "encoder/\(layer)/"
      for name in [
        "pre_hada_norm_0", "ZCRMSNorm_0", "post_attn_norm", "conv_norm",
        "conv_out_norm", "pre_hada_norm",
      ] { try take(p + name + "/scale", [512]) }
      for (name, out) in [
        ("q_proj", 384), ("k_proj", 96), ("v_proj", 128),
        ("gate_proj", 512), ("out_proj", 512),
      ] { try take(p + "self_attn/" + name + "/kernel", [out, 512], quantized: true) }
      for name in ["q_norm", "k_norm"] { try take(p + "self_attn/" + name + "/scale", [48]) }
      try take(p + "attn_gate", [1])
      try take(p + "pw1/kernel", [1024, 512], quantized: true)
      try take(p + "pw2/kernel", [512, 512], quantized: true)
      try take(p + "dw", [9, 512])
      for block in ["hadamard_mlp_0", "hadamard_mlp"] {
        for name in ["d1", "d2", "b2", "d3", "d4"] { try take(p + block + "/" + name, [512]) }
        for n in 1...3 {
          try take(p + block + "/w\(n)a", [16, 16])
          try take(p + block + "/w\(n)b", [32, 32])
        }
        try take(p + block + "/cond_v", [512, 8])
        try take(p + block + "/cond_u", [8, 512])
      }
    }
    try mhc("encoder")
    try take("encoder/final_norm/scale", [512])
    try take("stem/w", [9, 128])
    try take("stem/dw_1", [9, 128])
    try take("stem/pw_1/kernel", [128, 128], quantized: true)
    try take("stem/dw_2", [9, 128])
    try take("stem/pw_2/kernel", [128, 128], quantized: true)
    try take("stem/out/kernel", [512, 1280], quantized: true)
    try take("mel_filterbank", [257, 80])
    try require(cursor == 680, "unexpected tokenizer position")
    let raw = records[680]
    let tk = try WhistleTokenizer(data: data, offset: raw.offset, length: raw.nbytes)
    try require(tk.count == Int(h[5]), "tokenizer vocabulary mismatch")
    tensors = named
    tokenizer = tk
    mappedBytes = data.count
  }
}
