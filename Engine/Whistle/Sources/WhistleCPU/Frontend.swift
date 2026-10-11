import Accelerate
import Foundation

/// Pinned 16 kHz frontend. Recomputes only the supplied PCM prefix, as the research oracle does.
/// This is an unpaced replay frontend, not a microphone callback or an incremental FFT cache.
public final class WhistleFrontend {
  public enum Normalization: Sendable {
    case prefix, utterance
  }
  private let weights: WhistleWeights
  private let small: [String: [Float]]
  private let filterbank: [Double]
  private let setup: vDSP_DFT_SetupD
  private let window: [Double]

  public init(weights: WhistleWeights) throws {
    self.weights = weights
    var small: [String: [Float]] = [:]
    for name in ["stem/w", "stem/dw_1", "stem/dw_2", "pe_gate"] {
      let values = try weights.tensors[name]!.values()
      guard values.allSatisfy(\.isFinite) else {
        throw DecoderError.invalid("nonfinite frontend weight")
      }
      small[name] = values
    }
    self.small = small
    let bank = try weights.tensors["mel_filterbank"]!.values()
    guard bank.allSatisfy(\.isFinite),
      let setup = vDSP_DFT_zop_CreateSetupD(nil, 512, .FORWARD)
    else { throw DecoderError.invalid("invalid mel filterbank or FFT setup") }
    self.setup = setup
    filterbank = bank.map(Double.init)
    window = (0..<512).map { i in
      (56..<456).contains(i) ? 0.5 - 0.5 * cos(2 * .pi * Double(i - 56) / 400) : 0
    }
  }

  deinit { vDSP_DFT_DestroySetupD(setup) }

  /// Row-major frames x 80, no utterance-wide normalization.
  func logmel(_ audio: [Float]) throws -> [Float] {
    guard !audio.isEmpty, audio.count <= 960000, audio.allSatisfy(\.isFinite) else {
      throw DecoderError.invalid("PCM must contain 1...960000 finite samples at 16 kHz")
    }
    let frames = (audio.count + 159) / 160
    let batchSize = 64
    var power = [Double](repeating: 0, count: batchSize * 257)
    var mel = [Double](repeating: 0, count: batchSize * 80)
    var result = [Float](repeating: 0, count: frames * 80)
    var real = [Double](repeating: 0, count: 512)
    let imaginary = real
    var outReal = real
    var outImaginary = real
    for batchStart in stride(from: 0, to: frames, by: batchSize) {
      try Task.checkCancellation()
      let count = min(batchSize, frames - batchStart)
      for row in 0..<count {
        let t = batchStart + row
        for j in 0..<512 {
          var index = t * 160 + j - 256
          if audio.count == 1 {
            index = 0
          } else {
            let period = 2 * (audio.count - 1)
            index = ((index % period) + period) % period
            if index >= audio.count { index = period - index }
          }
          real[j] = Double(audio[index]) * window[j]
        }
        real.withUnsafeBufferPointer { rp in
          imaginary.withUnsafeBufferPointer { ip in
            outReal.withUnsafeMutableBufferPointer { ro in
              outImaginary.withUnsafeMutableBufferPointer { io in
                vDSP_DFT_ExecuteD(
                  setup, rp.baseAddress!, ip.baseAddress!, ro.baseAddress!, io.baseAddress!)
              }
            }
          }
        }
        for j in 0..<257 {
          power[row * 257 + j] = outReal[j] * outReal[j] + outImaginary[j] * outImaginary[j]
        }
      }
      power.withUnsafeBufferPointer { pp in
        filterbank.withUnsafeBufferPointer { bp in
          mel.withUnsafeMutableBufferPointer { mp in
            cblas_dgemm(
              CblasRowMajor, CblasNoTrans, CblasNoTrans,
              Int32(count), 80, 257, 1, pp.baseAddress!, 257, bp.baseAddress!, 80, 0,
              mp.baseAddress!, 80)
          }
        }
      }
      for j in 0..<count * 80 { result[batchStart * 80 + j] = Float(log(max(mel[j], 1e-10))) }
    }
    return result
  }

  public func forward(audio: [Float], normalization: Normalization = .prefix) throws
    -> EncoderFeatures
  {
    let warm = try logmel(normalization == .prefix ? Array(audio.prefix(32000)) : audio)
    let frames = warm.count / 80
    var mean = [Float](repeating: 0, count: 80)
    var std = mean
    for t in 0..<frames { for j in 0..<80 { mean[j] += warm[t * 80 + j] } }
    for j in 0..<80 { mean[j] /= Float(frames) }
    for t in 0..<frames {
      for j in 0..<80 {
        let d = warm[t * 80 + j] - mean[j]
        std[j] += d * d
      }
    }
    for j in 0..<80 { std[j] = sqrtf(std[j] / Float(frames)) + 1e-5 }
    var mel = normalization == .prefix ? try logmel(audio) : warm
    for i in mel.indices { mel[i] = (mel[i] - mean[i % 80]) / std[i % 80] }
    let melFrames = mel.count / 80
    let firstFrames = (melFrames + 1) / 2
    let secondFrames = (firstFrames + 1) / 2
    let time = (secondFrames + 1) / 2
    var stem: [Float] = []
    stem.reserveCapacity(time * 512)
    // Exact global stride/padding, with halos at each stage. Bound the largest volume
    // to <= 67 x 40 x 128 instead of repeatedly allocating utterance-wide stem volumes.
    for start in stride(from: 0, to: time, by: 16) {
      try Task.checkCancellation()
      let end = min(start + 16, time)
      let second = max(0, start * 2 - 1)..<min(secondFrames, (end - 1) * 2 + 2)
      let first =
        max(0, second.lowerBound * 2 - 1)..<min(firstFrames, (second.upperBound - 1) * 2 + 2)
      var x = convolve(
        mel, time: melFrames, frequency: 80, channels: 1, taps: small["stem/w"]!, outputRange: first
      )
      x = x.map { $0 * Math.sigmoid($0) }
      x = convolve(
        x, time: firstFrames, frequency: 40, channels: 128, taps: small["stem/dw_1"]!,
        inputStart: first.lowerBound, outputRange: second)
      x = try weights.tensors["stem/pw_1/kernel"]!.linear(
        Math.quantizeRows(x, width: 128), inputRows: second.count * 20)
      x = x.map { $0 * Math.sigmoid($0) }
      x = convolve(
        x, time: secondFrames, frequency: 20, channels: 128, taps: small["stem/dw_2"]!,
        inputStart: second.lowerBound, outputRange: start..<end)
      x = try weights.tensors["stem/pw_2/kernel"]!.linear(
        Math.quantizeRows(x, width: 128), inputRows: (end - start) * 10)
      x = x.map { $0 * Math.sigmoid($0) }
      // Channel-first flattening is part of the checkpoint contract (128 x 10).
      var flattened = [Float](repeating: 0, count: x.count)
      for t in 0..<end - start {
        for c in 0..<128 {
          for f in 0..<10 { flattened[(t * 128 + c) * 10 + f] = x[(t * 10 + f) * 128 + c] }
        }
      }
      stem.append(
        contentsOf: try weights.tensors["stem/out/kernel"]!.linear(
          Math.quantizeRows(flattened, width: 1280), inputRows: end - start))
    }
    let gate = Math.sigmoid(small["pe_gate"]![0])
    for t in 0..<time {
      for j in 0..<256 {
        let phase = Float(t) * expf(-logf(10000) * Float(j) / 255)
        stem[t * 512 + j] += gate * sinf(phase)
        stem[t * 512 + j + 256] += gate * cosf(phase)
      }
    }
    return try EncoderFeatures(values: stem, frames: time)
  }

  /// Fixed pad=1, stride=2 NHWC stem; channels=1 first conv, otherwise depthwise.
  private func convolve(
    _ x: [Float], time: Int, frequency: Int, channels: Int, taps: [Float], inputStart: Int = 0,
    outputRange: Range<Int>
  ) -> [Float] {
    let of = (frequency + 1) / 2
    var result = [Float](repeating: 0, count: outputRange.count * of * 128)
    for t in outputRange {
      for f in 0..<of {
        let base = ((t - outputRange.lowerBound) * of + f) * 128
        for kt in 0..<3 {
          let it = t * 2 + kt - 1
          guard it >= 0 && it < time else { continue }
          for kf in 0..<3 {
            let inf = f * 2 + kf - 1
            guard inf >= 0 && inf < frequency else { continue }
            let source = ((it - inputStart) * frequency + inf) * channels
            let weight = (kt * 3 + kf) * 128
            if channels == 1 {
              let value = x[source]
              for c in 0..<128 { result[base + c] += value * taps[weight + c] }
            } else {
              for c in 0..<128 { result[base + c] += x[source + c] * taps[weight + c] }
            }
          }
        }
      }
    }
    return result
  }
}
