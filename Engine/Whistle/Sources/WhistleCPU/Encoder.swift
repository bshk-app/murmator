import Foundation

/// Chunk=16, right=16, left=64, four mHC lanes. Weights remain deployment-packed.
public final class WhistleEncoder {
  fileprivate let weights: WhistleWeights
  fileprivate let small: [String: [Float]]
  private let permutations: [[Int]]

  public init(weights: WhistleWeights) throws {
    self.weights = weights
    var small: [String: [Float]] = [:]
    for (name, tensor) in weights.tensors
    where !tensor.isQuantized && (name.hasPrefix("encoder/") || name.hasPrefix("hada_p")) {
      let value = try tensor.values()
      guard value.allSatisfy(\.isFinite) else {
        throw DecoderError.invalid("nonfinite encoder weight")
      }
      small[name] = value
    }
    self.small = small
    var permutations: [[Int]] = []
    for name in ["hada_p1", "hada_p2"] {
      let floats = small[name]!
      guard floats.allSatisfy({ $0 >= 0 && $0 < 512 && $0.rounded() == $0 }),
        Set(floats).count == 512
      else { throw DecoderError.invalid("invalid encoder permutation") }
      permutations.append(floats.map(Int.init))
    }
    self.permutations = permutations
  }

  public func makeSession() -> WhistleEncoderSession { WhistleEncoderSession(model: self) }

  /// Isolated preview or final recovery: bidirectional attention over all rows,
  /// with fresh K/V and convolution state. Bound the quadratic work to 30 s.
  public func encodeWholeUtterance(_ stem: EncoderFeatures) throws -> EncoderFeatures {
    guard stem.frames <= 375 else { throw WhistleRecognitionError.windowLimit }
    var states = [EncoderState](repeating: EncoderState(), count: 8)
    let values = try chunk(stem.values, start: 0, commit: stem.frames, states: &states)
    return try EncoderFeatures(values: values, frames: stem.frames)
  }

  fileprivate func linear(_ name: String, _ x: [Float], rows: Int, range: Range<Int>? = nil) throws
    -> [Float]
  {
    try weights.tensors[name]!.linear(x, inputRows: rows, outputRows: range)
  }

  fileprivate func norm(_ x: [Float], _ name: String) -> [Float] {
    Math.normRows(x, scale: small[name]!)
  }

  private func mlp(_ input: [Float], root: String) -> [Float] {
    func w(_ name: String) -> [Float] { small[root + name]! }
    var out: [Float] = []
    out.reserveCapacity(input.count)
    for t in 0..<input.count / 512 {
      let x = Array(input[t * 512..<(t + 1) * 512])
      let soft = Math.softmax(Math.dense(x, w("cond_v"), outCount: 8))
      let cond = Math.dense(soft, w("cond_u"), outCount: 512).map { 1 + $0 }
      var z = Math.kron(zip(x, w("d1")).map(*), a: w("w1a"), aSize: 16, b: w("w1b"), bSize: 32)
      z = permutations[0].map { z[$0] }
      let d2 = w("d2")
      let b2 = w("b2")
      z = z.indices.map { i in
        let v = d2[i] * cond[i] * z[i] + b2[i]
        return v * Math.sigmoid(v)
      }
      z = Math.kron(z, a: w("w2a"), aSize: 16, b: w("w2b"), bSize: 32)
      z = permutations[1].map { z[$0] }
      z = Math.kron(zip(z, w("d3")).map(*), a: w("w3a"), aSize: 16, b: w("w3b"), bSize: 32)
      out.append(contentsOf: zip(z, w("d4")).map(*))
    }
    return out
  }

  fileprivate func chunk(
    _ stem: [Float], start: Int, commit: Int, states: inout [EncoderState],
    trace: ((Int, [Float]) -> Void)? = nil
  ) throws -> [Float] {
    let frames = stem.count / 512
    var stream: [Float] = []
    for t in 0..<frames {
      let row = Array(stem[t * 512..<(t + 1) * 512])
      for _ in 0..<4 { stream.append(contentsOf: row) }
    }
    for layer in 0..<8 {
      try Task.checkCancellation()
      var unit: [Float] = []
      for t in 0..<frames {
        unit.append(contentsOf: Math.unit(Array(stream[t * 2048..<(t + 1) * 2048])))
      }
      unit = Math.quantizeRows(unit, width: 2048)
      let root = "encoder/mhc_"
      func gates(_ name: String, _ width: Int) throws -> [Float] {
        let phi = try linear(
          root + "phi_" + name, unit, rows: frames, range: layer * width..<(layer + 1) * width)
        let a = small[root + "a_" + name]![layer]
        let b = small[root + "b_" + name]!
        return phi.indices.map { a * phi[$0] + b[layer * width + $0 % width] }
      }
      let pre = try gates("pre", 4).enumerated().map {
        Math.sigmoid($0.element + ($0.offset % 4 == layer % 4 ? 4 : -4))
      }
      var u = [Float](repeating: 0, count: frames * 512)
      for t in 0..<frames {
        for lane in 0..<4 {
          for j in 0..<512 {
            u[t * 512 + j] += pre[t * 4 + lane] * stream[(t * 4 + lane) * 512 + j]
          }
        }
      }
      let original = u
      let lp = "encoder/\(layer)/"
      let first = mlp(norm(u, lp + "pre_hada_norm_0/scale"), root: lp + "hadamard_mlp_0/")
      for j in u.indices { u[j] += 0.5 * first[j] }
      let att = try attention(
        norm(u, lp + "ZCRMSNorm_0/scale"), root: lp + "self_attn/", state: &states[layer],
        start: start, commit: commit)
      let normalizedAtt = norm(att, lp + "post_attn_norm/scale")
      let attGate = Math.sigmoid(small[lp + "attn_gate"]![0])
      for j in u.indices { u[j] += attGate * normalizedAtt[j] }
      let pw = try linear(
        lp + "pw1/kernel", Math.quantizeRows(norm(u, lp + "conv_norm/scale"), width: 512),
        rows: frames)
      var gated = [Float](repeating: 0, count: u.count)
      for t in 0..<frames {
        for j in 0..<512 {
          gated[t * 512 + j] = pw[t * 1024 + j] * Math.sigmoid(pw[t * 1024 + j + 512])
        }
      }
      let conv = convolve(gated, taps: small[lp + "dw"]!, state: &states[layer], commit: commit)
      let silu = norm(conv, lp + "conv_out_norm/scale").map { $0 * Math.sigmoid($0) }
      let residualConv = try linear(
        lp + "pw2/kernel", Math.quantizeRows(silu, width: 512), rows: frames)
      for j in u.indices { u[j] += residualConv[j] }
      let second = mlp(norm(u, lp + "pre_hada_norm/scale"), root: lp + "hadamard_mlp/")
      for j in u.indices { u[j] += 0.5 * second[j] }
      let post = try gates("post", 4).enumerated().map {
        2 * Math.sigmoid($0.element + ($0.offset % 4 == layer % 4 ? 0 : -4))
      }
      let rawResidual = try gates("res", 16)
      var next = [Float](repeating: 0, count: stream.count)
      for t in 0..<frames {
        let residual = Math.sinkhorn(Array(rawResidual[t * 16..<(t + 1) * 16]))
        for lane in 0..<4 {
          for j in 0..<512 {
            var value: Float = 0
            for prior in 0..<4 {
              value += residual[lane * 4 + prior] * stream[(t * 4 + prior) * 512 + j]
            }
            next[(t * 4 + lane) * 512 + j] =
              value + post[t * 4 + lane] * (u[t * 512 + j] - original[t * 512 + j])
          }
        }
      }
      stream = next
      trace?(layer, stream)
    }
    var mean = [Float](repeating: 0, count: commit * 512)
    for t in 0..<commit {
      for j in 0..<512 {
        for lane in 0..<4 { mean[t * 512 + j] += stream[(t * 4 + lane) * 512 + j] }
        mean[t * 512 + j] /= 4
      }
    }
    return norm(mean, "encoder/final_norm/scale")
  }

  private func attention(
    _ input: [Float], root: String, state: inout EncoderState, start: Int, commit: Int
  ) throws -> [Float] {
    let frames = input.count / 512
    let x = Math.quantizeRows(input, width: 512)
    var q = try linear(root + "q_proj/kernel", x, rows: frames)
    var k = try linear(root + "k_proj/kernel", x, rows: frames)
    var v = try linear(root + "v_proj/kernel", x, rows: frames)
    q = norm(q, root + "q_norm/scale")
    k = norm(k, root + "k_norm/scale")
    for t in 0..<frames {
      for h in 0..<8 { rope(&q, base: (t * 8 + h) * 48, position: start + t) }
      for h in 0..<2 { rope(&k, base: (t * 2 + h) * 48, position: start + t) }
    }
    q = Math.quantizeRows(q, width: 48)
    k = Math.quantizeRows(k, width: 48)
    v = Math.quantizeRows(v, width: 64)
    let oldFrames = state.keys.count / 96
    let keys = state.keys + k
    let values = state.values + v
    let count = oldFrames + frames
    var out = [Float](repeating: 0, count: frames * 512)
    for t in 0..<frames {
      for h in 0..<8 {
        var scores = [Float](repeating: 0, count: count)
        for kt in 0..<count {
          var dot: Float = 0
          for j in 0..<48 { dot += q[(t * 8 + h) * 48 + j] * keys[(kt * 2 + h / 4) * 48 + j] }
          scores[kt] = dot / sqrtf(48)
        }
        let probabilities = Math.softmax(scores)
        for kt in 0..<count {
          for j in 0..<64 {
            out[(t * 8 + h) * 64 + j] += probabilities[kt] * values[(kt * 2 + h / 4) * 64 + j]
          }
        }
      }
    }
    // Right-context rows are temporary. Retain only the last 64 committed rows.
    let end = oldFrames + commit
    let begin = max(0, end - 64)
    state.keys = Array(keys[begin * 96..<end * 96])
    state.values = Array(values[begin * 128..<end * 128])
    let gate = try linear(root + "gate_proj/kernel", x, rows: frames)
    for j in out.indices { out[j] *= Math.sigmoid(gate[j]) }
    return try linear(root + "out_proj/kernel", Math.quantizeRows(out, width: 512), rows: frames)
  }

  private func rope(_ x: inout [Float], base: Int, position: Int) {
    for j in 0..<24 {
      let angle = Float(position) / powf(100000, Float(2 * j) / 48)
      let c = cosf(angle)
      let s = sinf(angle)
      let a = x[base + j]
      let b = x[base + j + 24]
      x[base + j] = a * c - b * s
      x[base + j + 24] = a * s + b * c
    }
  }

  private func convolve(_ x: [Float], taps: [Float], state: inout EncoderState, commit: Int)
    -> [Float]
  {
    let frames = x.count / 512
    let values = state.convolution + x
    state.convolution = Array(values[commit * 512..<(commit + 4) * 512])
    var out = [Float](repeating: 0, count: x.count)
    for t in 0..<frames {
      for tap in 0..<9 where t + tap < frames + 4 {
        for j in 0..<512 { out[t * 512 + j] += values[(t + tap) * 512 + j] * taps[tap * 512 + j] }
      }
    }
    return out
  }
}

private struct EncoderState {
  var keys: [Float] = []
  var values: [Float] = []
  var convolution = [Float](repeating: 0, count: 4 * 512)
}

/// One utterance's persistent states. Lookahead is recomputed; committed encoder rows are not.
public final class WhistleEncoderSession {
  private let model: WhistleEncoder
  private var states = [EncoderState](repeating: EncoderState(), count: 8)
  public private(set) var position = 0
  public private(set) var closed = false
  public private(set) var projectedFrames = 0
  public var cachedKVFrames: [Int] { states.map { $0.keys.count / 96 } }
  public var convolutionFrames: [Int] { states.map { $0.convolution.count / 512 } }

  fileprivate init(model: WhistleEncoder) { self.model = model }

  /// Every nonfinal snapshot excludes the frontend's two unstable right-edge rows.
  public func append(
    _ stem: EncoderFeatures, final: Bool = false,
    trace: ((Int, [Float]) -> Void)? = nil
  ) throws -> [EncoderFeatures] {
    let available = final ? stem.frames : max(0, stem.frames - 2)
    guard !closed, available >= position else {
      throw DecoderError.invalid("closed or shrinking encoder snapshot")
    }
    let end = final ? available : position + max(0, available - position - 16) / 16 * 16
    var results: [EncoderFeatures] = []
    while position < end {
      let commit = min(16, end - position)
      let hi = min(available, position + commit + 16)
      let input = Array(stem.values[position * 512..<hi * 512])
      let encoded = try model.chunk(
        input, start: position, commit: commit, states: &states, trace: trace)
      results.append(try EncoderFeatures(values: encoded, frames: commit))
      projectedFrames += (hi - position) * 8
      position += commit
    }
    if final { closed = true }
    return results
  }
}
