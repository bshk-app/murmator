#if os(macOS)
  import Foundation
  import MurmurCore
  import MurmurSpeech

  @MainActor final class WhistleSessionSpeechDriver: SessionSpeechDriving {
    var onSnapshot: ((CaptionSnapshot) -> Void)?
    var onCapture: ((Int, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    private let session = WhistleSpeechSession()
    var capturedSeconds: Double { session.capturedSeconds }
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws {
      progress(.init(stage: .speech, fraction: nil))
      try await session.load { value in
        progress(.init(stage: .speech, fraction: value.fractionCompleted))
      }
    }
    private func callbacks() {
      session.onSnapshot = onSnapshot
      session.onCapture = onCapture
      session.onError = onError
      session.onRecordingError = onRecordingError
      session.onCaptureError = onCaptureError
      session.onTelemetry = onTelemetry
    }
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
      callbacks()
      try await session.start(microphoneUID: microphoneUID, recordingURL: recordingURL)
    }
    func replay(_ samples: [Float]) async throws -> SpeechReplayResult {
      callbacks()
      return try await session.replay(samples)
    }
    func stop() async throws -> String { try await session.stop() }
    func snapshot() async -> CaptionSnapshot { await session.snapshot() }
    func close() async { await session.close() }
  }
#endif
