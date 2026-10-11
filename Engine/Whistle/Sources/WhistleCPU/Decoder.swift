import Foundation

public enum DecoderError: Error, CustomStringConvertible {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}

/// Little-endian F32 cached encoder vectors; not an audio frontend or a native ASR session.
public struct EncoderFeatures: Sendable {
  public let values: [Float]
  public let frames: Int

  public init(values: [Float], frames: Int) throws {
    guard frames > 0, frames <= 4096, values.count == frames * 512,
      values.allSatisfy(\.isFinite)
    else { throw DecoderError.invalid("invalid encoder features") }
    self.values = values
    self.frames = frames
  }

  public init(url: URL) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    // Bound reads before allocation, including concurrently growing or oversized files.
    let data = try file.read(upToCount: 4096 * 512 * 4 + 1) ?? Data()
    guard !data.isEmpty, data.count % (512 * 4) == 0, data.count <= 4096 * 512 * 4 else {
      throw DecoderError.invalid("expected bounded, row-major F32 encoder features")
    }
    let values = data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 4).map {
        Float(
          bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))
        )
      }
    }
    try self.init(values: values, frames: data.count / (512 * 4))
  }
}

public struct DecoderResult: Codable, Sendable {
  public let text: String
  public let ids: [Int]
  public let endedWithEOS: Bool
}

/// Native Swift decoder proof. CQ weights stay packed; token caches live only within one draft.
/// Changed encoder vectors require a NEW session: text KV cannot be carried between redrafts.
public final class WhistleDecoder {
  fileprivate let weights: WhistleWeights
  fileprivate let small: [String: [Float]]
  fileprivate let permutations: [[Int]]

  public init(weights: WhistleWeights) throws {
    self.weights = weights
    var small: [String: [Float]] = [:]
    for (name, tensor) in weights.tensors
    where !tensor.isQuantized && !name.hasPrefix("encoder/")
      && !name.hasPrefix("stem/") && name != "mel_filterbank"
    {
      let count = tensor.shape.reduce(1) { current, dimension in
        current > 16384 || dimension <= 0 || dimension > 16384 / current
          ? 16385 : current * dimension
      }
      guard count <= 16384 else {
        throw DecoderError.invalid("unexpected dense weight extent: \(name)")
      }
      let value = try tensor.values()
      guard value.allSatisfy(\.isFinite) else {
        throw DecoderError.invalid("nonfinite weight: \(name)")
      }
      small[name] = value
    }
    self.small = small
    func require(_ name: String, _ shape: [Int]) throws {
      guard weights.tensors[name]?.shape == shape else {
        throw DecoderError.invalid("weight shape: \(name)")
      }
    }
    try require("embedding/embedding", [8199, 512])
    for i in 0..<8 {
      let root = "decoder/\(i)/"
      for (name, size) in [
        ("q_proj", 384), ("k_proj", 96), ("v_proj", 128),
        ("gate_proj", 512), ("out_proj", 512),
      ] {
        try require(root + "self_attn/" + name + "/kernel", [size, 512])
      }
      for (name, size) in [("q_taps", 384), ("k_taps", 96), ("v_taps", 128)] {
        try require(root + "self_attn/" + name, [3, size])
      }
      for name in ["q_norm", "k_norm"] { try require(root + "self_attn/" + name + "/scale", [48]) }
      for name in [
        "ZCRMSNorm_0", "post_attn_norm", "pre_hada_norm", "cross_norm", "post_cross_norm",
      ] {
        try require(root + name + "/scale", [512])
      }
      for name in ["attn_gate", "cross_gate"] { try require(root + name, [1]) }
      for name in ["q_proj", "k_proj", "v_proj", "gate_proj", "out_proj"] {
        try require(
          root + "cross_attn/" + name + "/kernel",
          [name == "q_proj" || name == "k_proj" ? 384 : 512, 512])
      }
      for name in ["q_norm", "k_norm"] { try require(root + "cross_attn/" + name + "/scale", [48]) }
      for name in ["d1", "d2", "b2", "d3", "d4"] {
        try require(root + "hadamard_mlp/" + name, [512])
      }
      for name in ["w1a", "w2a", "w3a"] { try require(root + "hadamard_mlp/" + name, [16, 16]) }
      for name in ["w1b", "w2b", "w3b"] { try require(root + "hadamard_mlp/" + name, [32, 32]) }
      try require(root + "hadamard_mlp/cond_v", [512, 8])
      try require(root + "hadamard_mlp/cond_u", [8, 512])
    }
    for name in ["pre", "post", "res"] {
      let out = name == "res" ? 16 : 4
      try require("stack/mhc_phi_" + name, [8 * out, 2048])
      guard small["stack/mhc_a_" + name]?.count == 8,
        small["stack/mhc_b_" + name]?.count == 8 * out
      else {
        throw DecoderError.invalid("mHC parameter shape")
      }
    }
    try require("stack/final_norm/scale", [512])
    for site in 0..<2 {
      let root = "engrams_\(site)/"
      try require(root + "embedding", [4 * 18432, 128])
      for name in ["key_proj", "value_proj"] { try require(root + name + "/kernel", [512, 512]) }
      try require(root + "taps", [4, 512])
    }
    var permutations: [[Int]] = []
    for name in ["hada_p1", "hada_p2"] {
      guard let floats = small[name], floats.count == 512,
        floats.allSatisfy({ $0 >= 0 && $0 < 512 && $0.rounded() == $0 })
      else {
        throw DecoderError.invalid("invalid Hadamard permutation")
      }
      let ints = floats.map { Int($0) }
      guard Set(ints).count == 512 else {
        throw DecoderError.invalid("duplicate Hadamard permutation")
      }
      permutations.append(ints)
    }
    self.permutations = permutations
  }

  public func logits(
    prefix: [Int], features: EncoderFeatures,
    trace: ((Int, [Float]) -> Void)? = nil
  ) throws -> [Float] {
    guard !prefix.isEmpty, prefix.count <= 320, prefix.allSatisfy({ (0..<8199).contains($0) })
    else {
      throw DecoderError.invalid("invalid token prefix")
    }
    let session = try Session(model: self, features: features)
    var result: [Float] = []
    for (index, token) in prefix.enumerated() {
      result = try session.step(
        token, emitLogits: index == prefix.count - 1,
        trace: index == prefix.count - 1 ? trace : nil)
    }
    return result
  }

  public func decode(
    features: EncoderFeatures, maxTokens: Int = 160, stopOnRepetition: Bool = false
  ) throws -> DecoderResult {
    guard maxTokens > 0, maxTokens <= 318 else {
      throw DecoderError.invalid("token budget must be 1...318")
    }
    let session = try Session(model: self, features: features)
    _ = try session.step(2, emitLogits: false)
    var logits = try session.step(8192, emitLogits: true)
    var ids: [Int] = []
    for index in 0..<maxTokens {
      try Task.checkCancellation()
      let token = logits.indices.max { logits[$0] < logits[$1] }!
      if token == 1 {
        return DecoderResult(text: try weights.tokenizer.decode(ids), ids: ids, endedWithEOS: true)
      }
      ids.append(token)
      if stopOnRepetition, Self.hasRepeatedTail(ids) {
        // A stalled first attempt requests a fresh final calculation. This is
        // never EOS and must not become confirmed text. The recovery decoder
        // does not use this heuristic, so real repeated speech remains possible.
        return DecoderResult(text: try weights.tokenizer.decode(ids), ids: ids, endedWithEOS: false)
      }
      if index + 1 < maxTokens { logits = try session.step(token, emitLogits: true) }
    }
    return DecoderResult(text: try weights.tokenizer.decode(ids), ids: ids, endedWithEOS: false)
  }

  /// At least two identical 4...16-token cycles plus the next two tokens.
  /// Single-word emphasis and a twice-repeated phrase do not trigger recovery.
  static func hasRepeatedTail(_ ids: [Int]) -> Bool {
    for period in 4...16 where ids.count >= period * 2 + 2 {
      let start = ids.count - period * 2 - 2
      if ((start + period)..<ids.count).allSatisfy({ ids[$0] == ids[$0 - period] }) {
        return true
      }
    }
    return false
  }

  fileprivate func linear(
    _ name: String, _ x: [Float], rows: Int = 1,
    outputRows: Range<Int>? = nil
  ) throws -> [Float] {
    try weights.tensors[name]!.linear(x, inputRows: rows, outputRows: outputRows)
  }

  fileprivate func norm(_ x: [Float], _ name: String) -> [Float] {
    Math.norm(x, scale: small[name]!)
  }

  fileprivate func mlp(_ x: [Float], layer: Int) -> [Float] {
    let root = "decoder/\(layer)/hadamard_mlp/"
    func w(_ name: String) -> [Float] { small[root + name]! }
    let soft = Math.softmax(Math.dense(x, w("cond_v"), outCount: 8))
    let cond = Math.dense(soft, w("cond_u"), outCount: 512).map { 1 + $0 }
    var z = Math.kron(zip(x, w("d1")).map(*), a: w("w1a"), aSize: 16, b: w("w1b"), bSize: 32)
    z = permutations[0].map { z[$0] }
    let d2 = w("d2")
    let b2 = w("b2")
    z = z.indices.map {
      let v = d2[$0] * cond[$0] * z[$0] + b2[$0]
      return v * Math.sigmoid(v)
    }
    z = Math.kron(z, a: w("w2a"), aSize: 16, b: w("w2b"), bSize: 32)
    z = permutations[1].map { z[$0] }
    z = Math.kron(zip(z, w("d3")).map(*), a: w("w3a"), aSize: 16, b: w("w3b"), bSize: 32)
    return zip(z, w("d4")).map(*)
  }
}

private final class Session {
  let model: WhistleDecoder
  let frames: Int
  var tokens: [Int] = []
  var selfKeys = [[Float]](repeating: [], count: 8)
  var selfValues = [[Float]](repeating: [], count: 8)
  var rawQ = [[[Float]]](repeating: [], count: 8)
  var rawK = [[[Float]]](repeating: [], count: 8)
  var rawV = [[[Float]]](repeating: [], count: 8)
  var engramValues = [[[Float]]](repeating: [], count: 2)
  var crossKeys: [[Float]] = []
  var crossValues: [[Float]] = []

  init(model: WhistleDecoder, features: EncoderFeatures) throws {
    self.model = model
    frames = features.frames
    var enc: [Float] = []
    enc.reserveCapacity(features.values.count)
    for i in 0..<frames {
      enc.append(contentsOf: Math.a8(Array(features.values[i * 512..<(i + 1) * 512])))
    }
    for i in 0..<8 {
      let root = "decoder/\(i)/cross_attn/"
      var k = try model.linear(root + "k_proj/kernel", enc, rows: frames)
      var v = try model.linear(root + "v_proj/kernel", enc, rows: frames)
      for t in 0..<frames {
        for h in 0..<8 {
          let start = t * 384 + h * 48
          let key = Math.a8(model.norm(Array(k[start..<start + 48]), root + "k_norm/scale"))
          k.replaceSubrange(start..<start + 48, with: key)
          let vs = t * 512 + h * 64
          v.replaceSubrange(vs..<vs + 64, with: Math.a8(Array(v[vs..<vs + 64])))
        }
      }
      crossKeys.append(k)
      crossValues.append(v)
      selfKeys[i].reserveCapacity(320 * 96)
      selfValues[i].reserveCapacity(320 * 128)
    }
  }

  func step(_ token: Int, emitLogits: Bool, trace: ((Int, [Float]) -> Void)? = nil) throws
    -> [Float]
  {
    guard tokens.count < 320 else { throw DecoderError.invalid("token context limit") }
    tokens.append(token)
    let siteKV = try engrams()
    let embedding = try model.weights.tensors["embedding/embedding"]!.row(token).map {
      $0 * sqrtf(512)
    }
    var stream = Array(repeating: embedding, count: 4).flatMap { $0 }
    for layer in 0..<8 {
      let x = Math.a8(Math.unit(stream))
      let root = "stack/mhc_"
      func gates(_ name: String, _ outCount: Int) throws -> [Float] {
        let phi = try model.linear(
          root + "phi_" + name, x, outputRows: layer * outCount..<(layer + 1) * outCount)
        let a = model.small[root + "a_" + name]![layer]
        let b = model.small[root + "b_" + name]!
        return phi.indices.map { a * phi[$0] + b[layer * outCount + $0] }
      }
      let pre = try gates("pre", 4).enumerated().map {
        Math.sigmoid($0.element + ($0.offset == layer % 4 ? 4 : -4))
      }
      var u = [Float](repeating: 0, count: 512)
      for lane in 0..<4 { for j in 0..<512 { u[j] += pre[lane] * stream[lane * 512 + j] } }
      let original = u
      if layer == 3 || layer == 7 {
        let site = layer == 3 ? 0 : 1
        let (key, value) = siteKV[site]
        let alpha = Math.sigmoid(
          zip(Math.unit(u), Math.unit(key)).reduce(Float(0)) { $0 + $1.0 * $1.1 } / sqrtf(512))
        for j in 0..<512 { u[j] += alpha * value[j] }
      }
      let lp = "decoder/\(layer)/"
      let att = try attention(model.norm(u, lp + "ZCRMSNorm_0/scale"), layer: layer)
      let normalizedAtt = model.norm(att, lp + "post_attn_norm/scale")
      let attGate = Math.sigmoid(model.small[lp + "attn_gate"]![0])
      for j in 0..<512 { u[j] += attGate * normalizedAtt[j] }
      let cross = try crossAttention(model.norm(u, lp + "cross_norm/scale"), layer: layer)
      let normalizedCross = model.norm(cross, lp + "post_cross_norm/scale")
      let crossGate = Math.sigmoid(model.small[lp + "cross_gate"]![0])
      for j in 0..<512 { u[j] += crossGate * normalizedCross[j] }
      let mlp = model.mlp(model.norm(u, lp + "pre_hada_norm/scale"), layer: layer)
      for j in 0..<512 { u[j] += mlp[j] }
      let delta = zip(u, original).map(-)
      let post = try gates("post", 4).enumerated().map {
        2 * Math.sigmoid($0.element + ($0.offset == layer % 4 ? 0 : -4))
      }
      let residual = Math.sinkhorn(try gates("res", 16))
      var next = [Float](repeating: 0, count: 2048)
      for i in 0..<4 {
        for j in 0..<512 {
          var v: Float = 0
          for lane in 0..<4 { v += residual[i * 4 + lane] * stream[lane * 512 + j] }
          next[i * 512 + j] = v + post[i] * delta[j]
        }
      }
      stream = next
      trace?(layer, stream)
    }
    guard emitLogits else { return [] }
    var mean = [Float](repeating: 0, count: 512)
    for j in 0..<512 {
      for lane in 0..<4 { mean[j] += stream[lane * 512 + j] }
      mean[j] /= 4
    }
    let x = Math.a8(model.norm(mean, "stack/final_norm/scale"))
    let logits = try model.linear("embedding/embedding", x, outputRows: 0..<8192)
    guard logits.allSatisfy(\.isFinite) else {
      throw DecoderError.invalid("nonfinite decoder output")
    }
    return logits
  }

  func engrams() throws -> [([Float], [Float])] {
    let position = tokens.count - 1
    var rows: [Int] = []
    for (oi, order) in [2, 3].enumerated() {
      for head in 0..<2 {
        var acc = UInt32(0x9e37_79b9) &* UInt32(oi * 2 + head + 1)
        for j in 0..<order {
          acc = (acc ^ UInt32(position >= j ? tokens[position - j] : 0)) &* 0x0100_0193
        }
        acc ^= acc >> 15
        rows.append((oi * 2 + head) * 18432 + Int(acc % 18432))
      }
    }
    var out: [([Float], [Float])] = []
    for site in 0..<2 {
      let root = "engrams_\(site)/"
      var e: [Float] = []
      for table in 0..<4 {
        if position >= [1, 1, 2, 2][table] {
          e.append(contentsOf: try model.weights.tensors[root + "embedding"]!.row(rows[table]))
        } else {
          e.append(contentsOf: [Float](repeating: 0, count: 128))
        }
      }
      e = Math.a8(e)
      let key = try model.linear(root + "key_proj/kernel", e)
      let value = try model.linear(root + "value_proj/kernel", e)
      engramValues[site].append(value)
      if engramValues[site].count > 10 { engramValues[site].removeFirst() }
      let history = engramValues[site]
      let taps = model.small[root + "taps"]!
      var convolved = [Float](repeating: 0, count: 512)
      for tap in 0..<4 where history.count > tap * 3 {
        let v = history[history.count - 1 - tap * 3]
        for j in 0..<512 { convolved[j] += taps[tap * 512 + j] * v[j] }
      }
      out.append((key, convolved))
    }
    return out
  }

  func convolve(_ history: inout [[Float]], value: [Float], taps: [Float]) -> [Float] {
    history.append(value)
    if history.count > 3 { history.removeFirst() }
    var out = [Float](repeating: 0, count: value.count)
    for tap in 0..<history.count {
      let v = history[history.count - 1 - tap]
      for j in out.indices { out[j] += taps[tap * out.count + j] * v[j] }
    }
    return out
  }

  func rope(_ v: [Float]) -> [Float] {
    var out = v
    let position = Float(tokens.count - 1)
    for j in 0..<24 {
      let angle = position / powf(100000, Float(2 * j) / 48)
      let c = cosf(angle)
      let s = sinf(angle)
      out[j] = v[j] * c - v[j + 24] * s
      out[j + 24] = v[j] * s + v[j + 24] * c
    }
    return out
  }

  func attention(_ input: [Float], layer: Int) throws -> [Float] {
    let x = Math.a8(input)
    let root = "decoder/\(layer)/self_attn/"
    var q = convolve(
      &rawQ[layer], value: try model.linear(root + "q_proj/kernel", x),
      taps: model.small[root + "q_taps"]!)
    var k = convolve(
      &rawK[layer], value: try model.linear(root + "k_proj/kernel", x),
      taps: model.small[root + "k_taps"]!)
    var v = convolve(
      &rawV[layer], value: try model.linear(root + "v_proj/kernel", x),
      taps: model.small[root + "v_taps"]!)
    for h in 0..<8 {
      let s = h * 48
      q.replaceSubrange(
        s..<s + 48, with: Math.a8(rope(model.norm(Array(q[s..<s + 48]), root + "q_norm/scale"))))
    }
    for h in 0..<2 {
      let s = h * 48
      k.replaceSubrange(
        s..<s + 48, with: Math.a8(rope(model.norm(Array(k[s..<s + 48]), root + "k_norm/scale"))))
      let vs = h * 64
      v.replaceSubrange(vs..<vs + 64, with: Math.a8(Array(v[vs..<vs + 64])))
    }
    selfKeys[layer].append(contentsOf: k)
    selfValues[layer].append(contentsOf: v)
    let out = attend(
      q, keys: selfKeys[layer], values: selfValues[layer], count: tokens.count, kvHeads: 2)
    let gate = try model.linear(root + "gate_proj/kernel", x)
    return try model.linear(
      root + "out_proj/kernel", Math.a8(zip(out, gate).map { $0 * Math.sigmoid($1) }))
  }

  func crossAttention(_ input: [Float], layer: Int) throws -> [Float] {
    let x = Math.a8(input)
    let root = "decoder/\(layer)/cross_attn/"
    var q = try model.linear(root + "q_proj/kernel", x)
    for h in 0..<8 {
      let s = h * 48
      q.replaceSubrange(
        s..<s + 48, with: Math.a8(model.norm(Array(q[s..<s + 48]), root + "q_norm/scale")))
    }
    let out = attend(
      q, keys: crossKeys[layer], values: crossValues[layer], count: frames, kvHeads: 8)
    let gate = try model.linear(root + "gate_proj/kernel", x)
    return try model.linear(
      root + "out_proj/kernel", Math.a8(zip(out, gate).map { $0 * Math.sigmoid($1) }))
  }

  func attend(_ query: [Float], keys: [Float], values: [Float], count: Int, kvHeads: Int) -> [Float]
  {
    var out = [Float](repeating: 0, count: 512)
    for h in 0..<8 {
      let kv = h / (8 / kvHeads)
      var scores = [Float](repeating: 0, count: count)
      for t in 0..<count {
        var dot: Float = 0
        for j in 0..<48 { dot += query[h * 48 + j] * keys[(t * kvHeads + kv) * 48 + j] }
        scores[t] = dot / sqrtf(48)
      }
      let probabilities = Math.softmax(scores)
      for t in 0..<count {
        for j in 0..<64 {
          out[h * 64 + j] += probabilities[t] * values[(t * kvHeads + kv) * 64 + j]
        }
      }
    }
    return out
  }
}
