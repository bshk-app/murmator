#if os(macOS)
  import Foundation
  import MurmurCore

  /// Mac CPU Fast candidate. Capture/recording share the ordinary app path; a
  /// bounded queue feeds inference off the main actor. Callbacks belong to one run.
  @MainActor public final class WhistleSpeechSession {
    public var onSnapshot: ((CaptionSnapshot) -> Void)?
    public var onCapture: ((Int, Float) -> Void)?
    public var onError: ((String) -> Void)?
    public var onRecordingError: ((String) -> Void)?
    public var onCaptureError: ((String) -> Void)?
    public var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    public private(set) var capturedSeconds = 0.0
    private let worker = WhistleSpeechWorker()
    private var run: SpeechCaptureRun?
    private var input: AsyncStream<[Float]>.Continuation?
    private var consumer: Task<Double, Error>?
    private var generation = UUID()
    private let telemetry = SpeechQualificationTelemetry()
    private var lastDraft = ""

    public init() {}
    public func load(progress: @escaping @MainActor @Sendable (Progress) -> Void = { _ in })
      async throws
    {
      try await worker.load(progress: progress)
    }
    private func begin() async throws -> (AsyncStream<[Float]>.Continuation, UUID) {
      guard consumer == nil else { throw CocoaError(.featureUnsupported) }
      generation = UUID()
      capturedSeconds = 0
      telemetry.reset()
      lastDraft = ""
      let token = generation
      let snapshot = onSnapshot
      let failure = onError
      try await worker.begin { [weak self] value in
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          if !value.provisional.isEmpty, value.provisional != self.lastDraft {
            self.lastDraft = value.provisional
            self.telemetry.observedPreview()
          }
          snapshot?(value)
          self.onTelemetry?(self.telemetry.snapshot())
        }
      }
      try Task.checkCancellation()
      guard generation == token else { throw CancellationError() }
      let (stream, continuation) = AsyncStream<[Float]>.makeStream()
      input = continuation
      consumer = Task { [weak self, worker] in
        var compute = 0.0
        for await chunk in stream {
          if Task.isCancelled { break }
          let began = ProcessInfo.processInfo.systemUptime
          let pending =
            self?.run?.backlog.pendingSamples ?? self?.replayBacklog?.0.pendingSamples ?? 0
          do { try await worker.step(chunk, allowPreview: pending <= 6144) } catch {
            if !(error is CancellationError), self?.generation == token {
              // The worker cleared its provisional text before failing.
              if let run = self?.run {
                self?.capturedSeconds = run.stop().0.durationS
              }
              failure?(error.localizedDescription)
            }
            continuation.finish()
            throw error
          }
          compute += ProcessInfo.processInfo.systemUptime - began
          self?.run?.backlog.release(chunk.count, generation: self?.run?.token ?? UUID())
          if let (backlog, budgetToken) = self?.replayBacklog {
            backlog.release(chunk.count, generation: budgetToken)
          }
          self?.telemetry.audioQueued(-1)
        }
        return compute
      }
      return (continuation, token)
    }

    public func start(microphoneUID: String?, recordingURL: URL?) async throws {
      let (input, token) = try await begin()
      let capture = SpeechCaptureRun(microphoneUID: microphoneUID)
      run = capture
      let captured = onCapture
      let captureError = onCaptureError
      let recordingError = onRecordingError
      do { try capture.recording.begin(url: recordingURL) } catch {
        await close()
        throw error
      }
      capture.mic.onCapture = { [weak self] count, _, peak, error in
        Task { @MainActor in
          guard let self, self.generation == token else { return }
          self.capturedSeconds += Double(count) / 16_000
          captured?(count, peak)
          if let error { captureError?(error) }
        }
      }
      capture.mic.onChunk = { [weak self, weak capture] audio in
        guard let capture else { return }
        switch capture.backlog.admit(audio.count, generation: capture.token) {
        case .closed: return
        case .overloaded:
          input.finish()
          DispatchQueue.global(qos: .userInitiated).async {
            _ = capture.stop()
            Task { @MainActor in
              guard self?.generation == token else { return }
              captureError?(
                "Speech recognition could not keep up. Capture stopped; accepted audio is being finalized."
              )
            }
          }
        case .accepted:
          do { try capture.recording.append(audio) } catch {
            Task { @MainActor in
              guard self?.generation == token else { return }
              recordingError?(error.localizedDescription)
            }
          }
          self?.telemetry.audioQueued(1)
          input.yield(audio)
        }
      }
      do { try capture.mic.start() } catch {
        await close()
        throw error
      }
    }

    public func stop() async throws -> String {
      let finalBegan = ProcessInfo.processInfo.systemUptime
      if let run {
        let (result, error) = run.stop()
        capturedSeconds = result.durationS
        if let error { onRecordingError?(error.localizedDescription) }
      }
      input?.finish()
      var recognitionFailure: Error?
      do { _ = try await consumer?.value } catch { recognitionFailure = error }
      consumer = nil
      input = nil
      run = nil
      defer {
        telemetry.finished(since: finalBegan)
        onTelemetry?(telemetry.snapshot())
      }
      if let recognitionFailure { throw recognitionFailure }
      return try await worker.finish()
    }

    public func replay(_ samples: [Float]) async throws -> SpeechReplayResult {
      guard samples.allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
      let (input, _) = try await begin()
      let began = ProcessInfo.processInfo.systemUptime
      let backlog = AudioBacklog()
      let token = backlog.reset()
      let telemetry = telemetry
      let producer = Task.detached {
        defer { input.finish() }
        for start in stride(from: 0, to: samples.count, by: 1536) {
          let end = min(start + 1536, samples.count)
          let delay = began + Double(end) / 16_000 - ProcessInfo.processInfo.systemUptime
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
          try Task.checkCancellation()
          telemetry.inputScheduleLag(
            max(0, ProcessInfo.processInfo.systemUptime - began - Double(end) / 16_000))
          guard backlog.admit(end - start, generation: token) == .accepted else {
            throw CocoaError(.coderInvalidValue)
          }
          telemetry.audioQueued(1)
          input.yield(Array(samples[start..<end]))
          // Replay admission is released by its consumer below.
        }
      }
      // Use the same queue bound as capture. The consumer releases this replay
      // budget after inference, including the currently executing audio chunk.
      replayBacklog = (backlog, token)
      defer { replayBacklog = nil }
      let consume = consumer
      do {
        return try await withTaskCancellationHandler(
          operation: {
            let compute = try await consume?.value ?? 0
            try await producer.value
            try Task.checkCancellation()
            let finalBegan = ProcessInfo.processInfo.systemUptime
            let text = try await worker.finish()
            telemetry.finished(since: began + Double(samples.count) / 16_000)
            onTelemetry?(telemetry.snapshot())
            capturedSeconds = Double(samples.count) / 16_000
            consumer = nil
            self.input = nil
            return .init(
              text: text, audioSeconds: capturedSeconds,
              computeSeconds: compute + ProcessInfo.processInfo.systemUptime - finalBegan,
              wallSeconds: ProcessInfo.processInfo.systemUptime - began)
          },
          onCancel: {
            producer.cancel()
            consume?.cancel()
            input.finish()
          })
      } catch {
        producer.cancel()
        input.finish()
        consumer?.cancel()
        _ = try? await producer.value
        await close()
        throw error
      }
    }
    private var replayBacklog: (AudioBacklog, UUID)?
    public func snapshot() async -> CaptionSnapshot { await worker.snapshot() }
    public func close() async {
      generation = UUID()
      consumer?.cancel()
      _ = run?.stop()
      run = nil
      input?.finish()
      _ = try? await consumer?.value
      consumer = nil
      input = nil
      await worker.close()
    }
  }
#endif
