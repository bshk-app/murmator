import Foundation
import os

/// The UI-agnostic dictation pipeline shared by the menu-bar app and the CLI:
/// load and warm the models, capture the mic in 96 ms chunks, stream the live
/// draft, and run the batch final on stop.
///
/// No SwiftUI, no hotkey library, no text injection — callers wire those. The
/// only difference between the app and the CLI is who drives `start()`/`stop()`
/// and what they do with the transcript.
///
/// `@unchecked Sendable`: `onUpdate` fires on the mic capture queue and `stop()`
/// is meant to be called off the main thread; `start()`/`stop()` never overlap
/// (the caller's state machine guarantees it).
public final class DictationSession: @unchecked Sendable {
    public static let liveChunkSamples = 1536 // 96 ms @ 16 kHz
    public static let recordUtterancesKey = "murmur.recordUtterances"
    /// Shared with every other pipeline built from the same `SpeechModels`.
    let engine: STTEngine
    private var mic = MicCapture()
    private var recordsUtterance = false
    private var recordedSamples: [Float] = []
    public private(set) var lastRecordingURL: URL?

    /// Live update per fed chunk: `(confirmed, provisional)`. Called on the mic
    /// capture queue — hop to your UI thread as needed.
    public var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)?
    /// Capture diagnostics: converted samples, input rate, raw peak, conversion error.
    public var onCapture: ((Int, Double, Float, String?) -> Void)?
    public private(set) var capturedSeconds: Double = 0
    public private(set) var capturedPeak: Float = 0

    public init(models: SpeechModels) {
        self.engine = models.engine
    }

    /// Ready to record in `mode` — its models are loaded and warmed.
    public func isReady(_ mode: DictationMode = .hybrid) -> Bool { engine.isReady(mode) }

    public var supportedLanguageCodes: [String] { engine.supportedLanguageCodes }

    /// Download (first run) + load + warm up ONLY the models `mode` needs. Heavy;
    /// await before `start(mode:)`. Defaults to hybrid (both lanes) for the CLI.
    public func load(mode: DictationMode = .hybrid) async throws {
        try await engine.prepare(mode)
    }

    /// Surface the microphone permission prompt early (no-op once granted).
    public func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void = { _ in }) {
        MicCapture.requestPermission(completion)
    }

    public func start(
        mode: DictationMode = .hybrid,
        language: String? = "auto",
        microphoneUID: String? = nil
    ) throws {
        recordsUtterance = UserDefaults.standard.bool(forKey: Self.recordUtterancesKey)
        recordedSamples.removeAll(keepingCapacity: recordsUtterance)
        lastRecordingURL = nil
        mic = MicCapture(inputDeviceUID: microphoneUID)
        engine.begin(language: language, mode: mode)
        mic.onCapture = { [weak self] frames, rate, peak, error in
            self?.onCapture?(frames, rate, peak, error)
        }
        mic.onChunk = { [weak self] chunk in
            guard let self else { return }
            if self.recordsUtterance { self.recordedSamples.append(contentsOf: chunk) }
            let (confirmed, partial) = self.engine.step(chunk)
            self.onUpdate?(confirmed, partial)
        }
        try mic.start()
    }

    /// Stop capture, run the batch final, and return that transcript.
    /// Releases the live lane first so leftover capture chunks are not decoded.
    @discardableResult
    public func stop() -> String {
        engine.releaseLive()
        let captured = mic.stop()
        capturedSeconds = captured.durationS
        capturedPeak = captured.peakRMS
        let final = engine.finish(capturedPeakRMS: captured.peakRMS)
        mic = MicCapture()
        // The recording is a diagnostic, not part of the transcript: writing it
        // here would put a megabyte of disk I/O between the user's stop gesture
        // and their text. Hand the samples to a background queue and return.
        scheduleDiagnosticRecording()
        return final
    }

    public func cancel() {
        engine.cancel()
        _ = mic.stop()
        mic = MicCapture()
        recordedSamples.removeAll()
    }

    /// The URL is decided here, on the caller's thread, and published here too:
    /// `start()` clears `lastRecordingURL`, so letting a background block assign it
    /// would race the next utterance — which `stop()` returning faster now makes
    /// more likely, not less. The background keeps only the bytes and the sweep.
    private func scheduleDiagnosticRecording() {
        guard recordsUtterance, !recordedSamples.isEmpty else { return }
        let samples = recordedSamples
        recordedSamples.removeAll(keepingCapacity: false)
        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let url = DiagnosticRecordings.directory()
            .appendingPathComponent("\(DiagnosticRecordings.filePrefix)\(stamp).wav")
        lastRecordingURL = url
        DispatchQueue.global(qos: .utility).async {
            Self.writeDiagnosticRecording(samples, to: url)
            DiagnosticRecordings.sweep()
        }
    }

    /// A failed diagnostic must never surface as a failed dictation, so this
    /// reports and returns rather than throwing.
    private static func writeDiagnosticRecording(_ samples: [Float], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try DiagnosticWAV.write(samples: samples, to: url)
            Logger(subsystem: "app.bshk.murmur", category: "diagnostic-audio").info("Diagnostic audio saved")
        } catch {
            Logger(subsystem: "app.bshk.murmur", category: "diagnostic-audio").error("Diagnostic audio failed: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
        }
    }

    /// Drive an utterance from externally paced chunks instead of the microphone.
    ///
    /// A benchmark producer delivers audio at 1x real time and timestamps the
    /// partials itself, so it needs to hand over chunks directly. Same engine and
    /// session lifecycle as `start()`/`stop()` — only the source differs.
    public func beginPaced(mode: DictationMode = .hybrid, language: String? = "auto") {
        engine.begin(language: language, mode: mode)
    }

    /// One paced chunk in, the current live view out (confirmed + provisional).
    public func stepPaced(_ samples: [Float]) -> String {
        let (confirmed, partial) = engine.step(samples)
        return partial.isEmpty ? confirmed : confirmed + " " + partial
    }

    /// End the utterance and return the final transcript. `beginPaced` starts the
    /// next one.
    public func finishPaced() -> String { engine.finish() }

    /// Offline transcription of pre-loaded 16 kHz mono samples, fed in the same
    /// chunks and with the same language prompt as the live path, with the STT
    /// compute timed — for benchmarking on a fixed file, no mic involved.
    public func transcribeOffline(
        _ samples: [Float],
        chunkSamples: Int = DictationSession.liveChunkSamples,
        mode: DictationMode = .hybrid,
        language: String? = "auto"
    ) -> OfflineResult {
        engine.begin(language: language, mode: mode)
        let wall0 = ProcessInfo.processInfo.systemUptime
        var compute = 0.0
        var i = 0
        while i < samples.count {
            let end = min(i + chunkSamples, samples.count)
            let chunk = Array(samples[i ..< end])
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = engine.step(chunk)
            compute += ProcessInfo.processInfo.systemUptime - t0
            i = end
        }
        let tf = ProcessInfo.processInfo.systemUptime
        let text = engine.finish()
        compute += ProcessInfo.processInfo.systemUptime - tf
        let wall = ProcessInfo.processInfo.systemUptime - wall0
        return OfflineResult(
            text: text,
            audioSeconds: Double(samples.count) / 16000.0,
            computeSeconds: compute,
            wallSeconds: wall
        )
    }
}

public struct OfflineResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    public let computeSeconds: Double   // sum of step + finish time
    public let wallSeconds: Double      // total incl. chunk slicing overhead
    public var rtf: Double { audioSeconds > 0 ? computeSeconds / audioSeconds : 0 }
}
