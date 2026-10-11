#if os(macOS)
  import Foundation
  import FluidAudio
  import MurmurCore
  import WhistleCPU

  /// CPU inference is isolated from capture and the UI. Silence is screened by
  /// streaming Core ML Silero; previews are replaceable until pause/cap/EOF.
  actor WhistleSpeechWorker {
    private var model: WhistleRecognizer?
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()
    private var utterance: WhistleUtterance?
    private var tail: [Float] = []
    private var preroll: [Float] = []
    private var silentSamples = 0
    private var processedSamples = 0
    private var startSample = 0
    private var nextID: UInt64 = 1
    private var confirmed: [CaptionSegment] = []
    private var provisional = ""
    private var revision: UInt64 = 0
    private var generation = UUID()
    private var active = false
    private var failure: Error?
    private var callback: (@Sendable (CaptionSnapshot) -> Void)?

    func load(progress: @escaping @MainActor @Sendable (Progress) -> Void) async throws {
      let token = generation
      let url = try await WhistleAssets.prepare(onProgress: progress)
      try check(token)
      let loaded = try WhistleRecognizer(weightsURL: url)
      let detector = try await VadManager(config: VadConfig(computeUnits: .cpuOnly))
      try check(token)
      _ = try await detector.process([Float](repeating: 0, count: VadManager.chunkSize))
      try check(token)
      model = loaded
      vad = detector
    }
    func begin(callback: @escaping @Sendable (CaptionSnapshot) -> Void) throws {
      guard model != nil, vad != nil else { throw CocoaError(.featureUnsupported) }
      generation = UUID()
      active = true
      failure = nil
      utterance = nil
      tail = []
      preroll = []
      silentSamples = 0
      processedSamples = 0
      confirmed = []
      provisional = ""
      revision = 0
      nextID = 1
      vadState = .initial()
      self.callback = callback
    }
    private func check(_ token: UUID) throws {
      try Task.checkCancellation()
      guard generation == token else { throw CancellationError() }
    }
    func step(_ audio: [Float], allowPreview: Bool = true) async throws {
      if let failure { throw failure }
      guard active else { throw CancellationError() }
      let token = generation
      do {
        guard audio.allSatisfy(\.isFinite), audio.count <= 16_000 else {
          throw WhistleRecognitionError.invalidPCM
        }
        tail.append(contentsOf: audio)
        while tail.count >= VadManager.chunkSize {
          let frame = Array(tail.prefix(VadManager.chunkSize))
          tail.removeFirst(VadManager.chunkSize)
          try await process(frame, token: token, allowPreview: allowPreview)
        }
      } catch {
        // A failed final is never replaced with a truncated preview.
        if generation == token {
          failure = error
          provisional = ""
          utterance = nil
          emit()
        }
        throw error
      }
    }
    private func process(_ frame: [Float], token: UUID, allowPreview: Bool) async throws {
      guard let vad, let model else { throw CocoaError(.featureUnsupported) }
      var padded = frame
      if padded.count < VadManager.chunkSize {
        padded.append(contentsOf: repeatElement(0, count: VadManager.chunkSize - padded.count))
      }
      let result = try await vad.processStreamingChunk(padded, state: vadState)
      try check(token)
      vadState = result.state
      let speech = result.probability >= 0.5
      if let utterance, utterance.sampleCount + frame.count > WhistleRecognizer.maximumSamples {
        try finalize()
      }
      if utterance == nil, speech {
        startSample = processedSamples - preroll.count
        utterance = model.makeUtterance()
        try utterance?.append(preroll)
        preroll = []
      }
      if let utterance {
        if let draft = try utterance.append(frame, allowPreview: allowPreview),
          draft.text != provisional
        {
          provisional = draft.text
          emit()
        }
        silentSamples = speech ? 0 : silentSamples + frame.count
      } else {
        // The coarse 256 ms detector can need several frames to recognize an
        // onset. Preserve three frames so the first consonant reaches ASR.
        preroll.append(contentsOf: frame)
        if preroll.count > 12_288 { preroll.removeFirst(preroll.count - 12_288) }
      }
      processedSamples += frame.count
      if utterance != nil, silentSamples >= 12_288 { try finalize() }
    }
    private func finalize() throws {
      guard let utterance else { return }
      let result = try utterance.finish()
      if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        confirmed.append(
          .init(
            id: nextID, startSample: startSample, endSample: processedSamples,
            text: result.text, state: .confirmed))
        nextID += 1
      }
      self.utterance = nil
      provisional = ""
      silentSamples = 0
      preroll = []
      emit()
    }
    func finish() async throws -> String {
      if let failure { throw failure }
      guard active else { return confirmed.map(\.text).joined(separator: " ") }
      let token = generation
      do {
        if !tail.isEmpty {
          let frame = tail
          tail = []
          try await process(frame, token: token, allowPreview: false)
        }
        try check(token)
        try finalize()
        active = false
        emit()
        return confirmed.map(\.text).joined(separator: " ")
      } catch {
        if generation == token {
          failure = error
          active = false
          provisional = ""
          utterance = nil
          emit()
        }
        throw error
      }
    }
    func snapshot() -> CaptionSnapshot {
      .init(
        revision: revision, confirmed: confirmed, provisional: provisional,
        settledThroughSample: confirmed.last?.endSample ?? 0)
    }
    private func emit() {
      revision += 1
      callback?(snapshot())
    }
    func close() {
      generation = UUID()
      active = false
      callback = nil
      utterance = nil
      tail = []
      preroll = []
      confirmed = []
      provisional = ""
      model = nil
      vad = nil
    }
  }
#endif
