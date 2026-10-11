import Accelerate
import Foundation

enum Math {
  static func quantizeRows(_ x: [Float], width: Int) -> [Float] {
    precondition(width > 0 && x.count % width == 0)
    var out = x
    for start in stride(from: 0, to: x.count, by: width) {
      var maximum: Float = 0
      for j in start..<start + width { maximum = max(maximum, abs(x[j])) }
      let scale: Float = maximum > 0 ? maximum / 127 : 1
      for j in start..<start + width {
        out[j] = min(127, max(-128, (x[j] / scale).rounded(.toNearestOrEven))) * scale
      }
    }
    return out
  }

  static func normRows(_ x: [Float], scale: [Float]) -> [Float] {
    let width = scale.count
    precondition(width > 0 && x.count % width == 0)
    var out = x
    for start in stride(from: 0, to: x.count, by: width) {
      var sum: Float = 0
      for j in start..<start + width { sum += x[j] * x[j] }
      let rms = sqrtf(sum / Float(width) + 1e-6)
      for j in 0..<width { out[start + j] = (1 + scale[j]) * x[start + j] / rms }
    }
    return out
  }

  static func sigmoid(_ x: Float) -> Float { 1 / (1 + expf(-x)) }

  static func a8(_ x: [Float]) -> [Float] {
    let maximum = x.reduce(Float(0)) { max($0, abs($1)) }
    let scale: Float = maximum > 0 ? maximum / 127 : 1
    return x.map { min(127, max(-128, ($0 / scale).rounded(.toNearestOrEven))) * scale }
  }

  static func unit(_ x: [Float]) -> [Float] {
    let inv = 1 / sqrtf(x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count) + 1e-6)
    return x.map { $0 * inv }
  }

  static func norm(_ x: [Float], scale: [Float]) -> [Float] {
    precondition(!x.isEmpty && scale.count == x.count)
    let rms = sqrtf(x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count) + 1e-6)
    return zip(x, scale).map { (1 + $1) * $0 / rms }
  }

  static func softmax(_ x: [Float]) -> [Float] {
    precondition(!x.isEmpty)
    let maximum = x.max()!
    let y = x.map { expf($0 - maximum) }
    let sum = y.reduce(Float(0), +)
    return y.map { $0 / sum }
  }

  static func logsumexp(_ x: [Float]) -> Float {
    let maximum = x.max()!
    return maximum + logf(x.reduce(Float(0)) { $0 + expf($1 - maximum) })
  }

  static func sinkhorn(_ x: [Float]) -> [Float] {
    precondition(x.count == 16)
    var r = x
    for _ in 0..<20 {
      for i in 0..<4 {
        let v = logsumexp(Array(r[(i * 4)..<(i * 4 + 4)]))
        for j in 0..<4 { r[i * 4 + j] -= v }
      }
      for j in 0..<4 {
        let v = logsumexp((0..<4).map { r[$0 * 4 + j] })
        for i in 0..<4 { r[i * 4 + j] -= v }
      }
    }
    return r.map { expf($0) }
  }

  // Small unquantized matrices are kept as F32; CQ matrices use PackedTensor.linear.
  static func dense(_ x: [Float], _ w: [Float], outCount: Int) -> [Float] {
    precondition(!x.isEmpty && outCount > 0 && w.count == x.count * outCount)
    var out = [Float](repeating: 0, count: outCount)
    w.withUnsafeBufferPointer { wp in
      x.withUnsafeBufferPointer { xp in
        out.withUnsafeMutableBufferPointer { op in
          cblas_sgemv(
            CblasRowMajor, CblasTrans, Int32(x.count), Int32(outCount),
            1, wp.baseAddress!, Int32(outCount), xp.baseAddress!, 1,
            0, op.baseAddress!, 1)
        }
      }
    }
    return out
  }

  static func kron(_ z: [Float], a: [Float], aSize: Int, b: [Float], bSize: Int) -> [Float] {
    precondition(z.count == aSize * bSize && a.count == aSize * aSize && b.count == bSize * bSize)
    var tmp = [Float](repeating: 0, count: z.count)
    var out = tmp
    a.withUnsafeBufferPointer { ap in
      z.withUnsafeBufferPointer { zp in
        tmp.withUnsafeMutableBufferPointer { tp in
          cblas_sgemm(
            CblasRowMajor, CblasTrans, CblasNoTrans,
            Int32(aSize), Int32(bSize), Int32(aSize), 1,
            ap.baseAddress!, Int32(aSize), zp.baseAddress!, Int32(bSize),
            0, tp.baseAddress!, Int32(bSize))
        }
      }
    }
    tmp.withUnsafeBufferPointer { tp in
      b.withUnsafeBufferPointer { bp in
        out.withUnsafeMutableBufferPointer { op in
          cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(aSize), Int32(bSize), Int32(bSize), 1,
            tp.baseAddress!, Int32(bSize), bp.baseAddress!, Int32(bSize),
            0, op.baseAddress!, Int32(bSize))
        }
      }
    }
    return out
  }
}
