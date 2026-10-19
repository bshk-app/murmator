import Foundation
import MurmurCore
import MurmurSpeech
import MurmurSession
import AIProvidersCore

/// A single local microphone writes checkpointed PCM before recognition. Cloud
/// refinement reads only closed phrase ranges while the local draft continues.
@MainActor final class LocalCloudRefiningDriver: SessionSpeechDriving {
    var onSnapshot: ((CaptionSnapshot) -> Void)?
    var onCapture: ((Int, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onRecordingError: ((String) -> Void)?
    var onCaptureError: ((String) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    var capturedSeconds: Double { base.capturedSeconds }
    private let base: any SessionSpeechDriving
    private let provider: any AISpeechProviding
    private let request: AISpeechRequest
    private var file: URL?
    private var temporary = false
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var value = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
    private var corrections: [UInt64: String] = [:]
    private var jobs: [UInt64: Task<Void, Never>] = [:]
    private var latestRefinement: Task<Void, Never>?
    init(base: any SessionSpeechDriving, provider: any AISpeechProviding, request: AISpeechRequest) { self.base = base; self.provider = provider; self.request = request }
    func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws { try await base.prepare(progress: progress) }
    func start(microphoneUID: String?, recordingURL: URL?) async throws {
        generation = UUID(); let token = generation; revision = 0; jobs = [:]; corrections = [:]
        temporary = recordingURL == nil
        file = recordingURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("murmur-cloud-\(token).wav")
        base.onSnapshot = { [weak self] value in guard let self, self.generation == token else { return }; self.accept(value, token: token) }
        base.onCapture = { [weak self] frames, peak in guard let self, self.generation == token else { return }; self.onCapture?(frames, peak) }
        base.onError = { [weak self] error in guard let self, self.generation == token else { return }; self.onError?(error) }
        base.onCaptureError = { [weak self] error in guard let self, self.generation == token else { return }; self.onCaptureError?(error) }
        base.onRecordingError = { [weak self] error in guard let self, self.generation == token else { return }; self.onRecordingError?(error) }
        try await base.start(microphoneUID: microphoneUID, recordingURL: file)
    }
    private func accept(_ snapshot: CaptionSnapshot, token: UUID) {
        value = snapshot
        for segment in snapshot.confirmed where segment.state == .confirmed && !segment.text.isEmpty && jobs[segment.id] == nil {
            guard let file, let end = segment.endSample, end > segment.startSample, segment.startSample >= 0 else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(44 + segment.startSample * 2))
                let count = (end - segment.startSample) * 2
                guard let data = try handle.read(upToCount: count), data.count == count else { continue }
                let wav = ProviderSpeechDriver.wav(data), provider = provider, request = request
                onSpeech?(.correctionStarted(id: segment.id, audioSeconds: Double(end - segment.startSample) / 16000))
                let preceding = latestRefinement
                let task = Task { [weak self] in
                    let started = Date()
                    do {
                        await preceding?.value; try Task.checkCancellation()
                        let text = try await provider.transcribe(wav, request: request); try Task.checkCancellation()
                        guard let self, self.generation == token else { return }
                        self.corrections[segment.id] = text; self.publish()
                        self.onSpeech?(.correctionFinished(id: segment.id, text: text, seconds: Date().timeIntervalSince(started)))
                    } catch {
                        guard let self, self.generation == token, !Task.isCancelled else { return }
                        self.onSpeech?(.correctionFailed(id: segment.id, message: error.localizedDescription))
                    }
                }
                jobs[segment.id] = task; latestRefinement = task
            } catch { onRecordingError?(error.localizedDescription) }
        }
        publish()
    }
    private func current() -> CaptionSnapshot {
        var segments = value.confirmed
        for index in segments.indices { if let text = corrections[segments[index].id] { segments[index].text = text } }
        return .init(revision: revision, confirmed: segments, provisional: value.provisional)
    }
    private func publish() { revision &+= 1; onSnapshot?(current()) }
    func snapshot() async -> CaptionSnapshot { current() }
    func stop() async throws -> String {
        let token = generation
        let fallback = try await base.stop()
        guard token == generation else { throw CancellationError() }
        let ending = await base.snapshot()
        if !ending.provisional.isEmpty {
            let id = (ending.confirmed.map(\.id).max() ?? 0) + 1
            let start = ending.confirmed.last?.endSample ?? 0
            let tail = CaptionSegment(id: id, startSample: start, endSample: max(start + 1, Int(capturedSeconds * 16000)), text: ending.provisional, state: .confirmed)
            accept(.init(revision: ending.revision + 1, confirmed: ending.confirmed + [tail], provisional: ""), token: token)
        } else { accept(ending, token: token) }
        for job in jobs.values { await job.value }
        try Task.checkCancellation(); guard token == generation else { throw CancellationError() }
        let text = current().confirmed.map(\.text).joined(separator: " ")
        return text.isEmpty ? fallback : text
    }
    func close() async {
        generation = UUID(); for job in jobs.values { job.cancel() }; await base.close()
        if temporary, let file { try? FileManager.default.removeItem(at: file) }; file = nil
    }
}
