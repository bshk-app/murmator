import Foundation

public enum WhistleRecognitionError: Error, LocalizedError {
  case closed, invalidPCM, windowLimit, incompleteFinal
  public var errorDescription: String? {
    switch self {
    case .closed: return "The Whistle utterance has ended."
    case .invalidPCM: return "Whistle requires finite mono 16 kHz PCM."
    case .windowLimit: return "Whistle requires audio windows of at most 30 seconds."
    case .incompleteFinal:
      return "Whistle could not complete this audio window. Try a shorter phrase."
    }
  }
}

public struct WhistleCompute: Codable, Sendable {
  public fileprivate(set) var frontendSeconds = 0.0
  public fileprivate(set) var encoderSeconds = 0.0
  public fileprivate(set) var decoderSeconds = 0.0
  public fileprivate(set) var drafts = 0
  public fileprivate(set) var finalRetries = 0
  public var totalSeconds: Double { frontendSeconds + encoderSeconds + decoderSeconds }
}

/// One loaded model, used serially by its owner. Independent utterances get fresh
/// encoder and decoder states; deployment weights stay packed and memory mapped.
public final class WhistleRecognizer {
  public static let sampleRate = 16_000
  public static let maximumSamples = 30 * sampleRate
  private let frontend: WhistleFrontend
  private let encoder: WhistleEncoder
  private let decoder: WhistleDecoder

  public init(weightsURL: URL) throws {
    let weights = try WhistleWeights(url: weightsURL)
    frontend = try WhistleFrontend(weights: weights)
    encoder = try WhistleEncoder(weights: weights)
    decoder = try WhistleDecoder(weights: weights)
  }

  public func makeUtterance() -> WhistleUtterance {
    WhistleUtterance(frontend: frontend, encoder: encoder, decoder: decoder)
  }
}

/// An isolated first preview after 2 seconds, followed by cached previews
/// starting at 2.8 seconds (normalization + right context). EOF drains all remaining encoder
/// chunks, then decodes a final. A looping or token-limited final retries from all
/// PCM with whole-phrase normalization and full encoder context. Confirmation requires EOS.
/// Confine this object and its model to one serial executor.
public final class WhistleUtterance {
  public static let firstPreviewSamples = 32_000
  private static let firstStreamingPreviewSamples = 44_800
  public static let previewStrideSamples = 20_480
  public private(set) var sampleCount = 0
  public private(set) var closed = false
  public private(set) var compute = WhistleCompute()
  public var encoderFrames: Int { encoder.position }
  public var projectedFrames: Int { encoder.projectedFrames + isolatedProjectedFrames }
  private let frontend: WhistleFrontend
  private let encoderModel: WhistleEncoder
  private let encoder: WhistleEncoderSession
  private let decoder: WhistleDecoder
  private var audio: [Float] = []
  private var encoded: [Float] = []
  private var nextPreview = firstPreviewSamples
  private var isolatedProjectedFrames = 0

  fileprivate init(
    frontend: WhistleFrontend, encoder: WhistleEncoder, decoder: WhistleDecoder
  ) {
    self.frontend = frontend
    encoderModel = encoder
    self.encoder = encoder.makeSession()
    self.decoder = decoder
  }

  @discardableResult public func append(_ samples: [Float], allowPreview: Bool = true) throws
    -> DecoderResult?
  {
    guard !closed else { throw WhistleRecognitionError.closed }
    guard samples.allSatisfy(\.isFinite) else { throw WhistleRecognitionError.invalidPCM }
    guard samples.count <= WhistleRecognizer.maximumSamples - sampleCount else {
      throw WhistleRecognitionError.windowLimit
    }
    try Task.checkCancellation()
    audio.append(contentsOf: samples)
    sampleCount += samples.count
    guard allowPreview, sampleCount >= nextPreview else { return nil }
    do {
      if sampleCount < Self.firstStreamingPreviewSamples {
        // Short-prefix normalization and missing lookahead are useful for a
        // replaceable draft, but must never enter the persistent encoder cache.
        nextPreview = Self.firstStreamingPreviewSamples
        let began = ProcessInfo.processInfo.systemUptime
        let stem = try frontend.forward(audio: audio)
        let encodedAt = ProcessInfo.processInfo.systemUptime
        compute.frontendSeconds += encodedAt - began
        let features = try encoderModel.encodeWholeUtterance(stem)
        isolatedProjectedFrames += stem.frames * 8
        compute.encoderSeconds += ProcessInfo.processInfo.systemUptime - encodedAt
        return try decode(features: features, budget: 32, stopOnRepetition: true)
      }
      // Coalesce a large append into one current preview, never obsolete redrafts.
      nextPreview = sampleCount + Self.previewStrideSamples
      try encode(final: false)
      guard !encoded.isEmpty else { return nil }
      // Six tokens/sec allows previews to grow with speech, while limiting early
      // repetition on a prefix whose sentence is still incomplete.
      let budget = min(160, max(32, encoderFrames * 6 * 1280 / 16_000))
      return try decode(budget: budget)
    } catch {
      closed = true
      throw error
    }
  }

  public func finish() throws -> DecoderResult {
    guard !closed else { throw WhistleRecognitionError.closed }
    closed = true
    defer {
      audio.removeAll()
      encoded.removeAll()
    }
    try Task.checkCancellation()
    guard sampleCount > 0 else { return DecoderResult(text: "", ids: [], endedWithEOS: true) }
    try encode(final: true)
    var result = try decode(budget: 318, stopOnRepetition: true)
    if !result.endedWithEOS {
      // The fixed two-second statistics used for streaming can be sensitive to
      // VAD boundaries. Retry with final PCM statistics and bidirectional
      // context, never promote a draft or invent EOS. Rebuild every encoder row.
      compute.finalRetries += 1
      let began = ProcessInfo.processInfo.systemUptime
      let stem = try frontend.forward(audio: audio, normalization: .utterance)
      let encodedAt = ProcessInfo.processInfo.systemUptime
      compute.frontendSeconds += encodedAt - began
      encoded = try encoderModel.encodeWholeUtterance(stem).values
      isolatedProjectedFrames += stem.frames * 8
      compute.encoderSeconds += ProcessInfo.processInfo.systemUptime - encodedAt
      result = try decode(budget: 318)
    }
    guard result.endedWithEOS else { throw WhistleRecognitionError.incompleteFinal }
    return result
  }

  private func encode(final: Bool) throws {
    let began = ProcessInfo.processInfo.systemUptime
    let stem = try frontend.forward(audio: audio)
    let encodedAt = ProcessInfo.processInfo.systemUptime
    compute.frontendSeconds += encodedAt - began
    for part in try encoder.append(stem, final: final) { encoded.append(contentsOf: part.values) }
    compute.encoderSeconds += ProcessInfo.processInfo.systemUptime - encodedAt
  }

  private func decode(
    features: EncoderFeatures? = nil, budget: Int, stopOnRepetition: Bool = false
  ) throws -> DecoderResult {
    let began = ProcessInfo.processInfo.systemUptime
    let result = try decoder.decode(
      features: features ?? EncoderFeatures(values: encoded, frames: encoderFrames),
      maxTokens: budget,
      stopOnRepetition: stopOnRepetition)
    compute.decoderSeconds += ProcessInfo.processInfo.systemUptime - began
    compute.drafts += 1
    return result
  }
}
