import Foundation
import MurmurCore
import MurmurSpeech
import MurmurSession
import AIProvidersCore

@MainActor public final class ProviderSpeechDriver: SessionSpeechDriving {
    public var onSnapshot: ((CaptionSnapshot) -> Void)?
    public var onCapture: ((Int, Float) -> Void)?
    public var onError: ((String) -> Void)?
    public var onRecordingError: ((String) -> Void)?
    public var onCaptureError: ((String) -> Void)?
    public var onSpeech: ((SpeechEvent) -> Void)?
    public var onTelemetry: ((SpeechQualificationSnapshot) -> Void)?
    public private(set) var capturedSeconds = 0.0
    private let provider: any AISpeechProviding
    private let request: AISpeechRequest
    private let mode: DictationMode
    private let refinement: (any AISpeechProviding)?
    private let refinementRequest: AISpeechRequest?
    private var capture: MicCapture?
    private var socket: (any AISpeechStreaming)?
    private let sink = RecordingAudioSink()
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var feed: Task<Void, Error>?
    private var reader: Task<Void, Error>?
    private var jobs: [UInt64: Task<Void, Never>] = [:]
    private var latestRefinement: Task<Void, Never>?
    private var pcm = Data()
    private var confirmed: [CaptionSegment] = []
    private var provisional = ""
    private var revision: UInt64 = 0
    private var generation = UUID()
    private var failure: Error?
    public init(provider: any AISpeechProviding, request: AISpeechRequest, mode: DictationMode,
                refinement: (any AISpeechProviding)? = nil, refinementRequest: AISpeechRequest? = nil) {
        self.provider = provider; self.request = request; self.mode = mode; self.refinement = refinement; self.refinementRequest = refinementRequest
    }
    public func prepare(progress: @escaping (RecordingSession.Preparation) -> Void) async throws {
        if let local = refinement as? LocalSpeechFileProvider {
            progress(.init(stage: .speech, fraction: nil)); try await local.prepare()
        }
        try Task.checkCancellation()
    }
    public func snapshot() async -> CaptionSnapshot { .init(revision: revision, confirmed: confirmed, provisional: provisional) }
    private func publish() { revision &+= 1; onSnapshot?(.init(revision: revision, confirmed: confirmed, provisional: provisional)) }
    public func start(microphoneUID: String?, recordingURL: URL?) async throws {
        let token = UUID(); generation = token; failure = nil; capturedSeconds = 0
        pcm = Data(); confirmed = []; provisional = ""; revision = 0; jobs = [:]
        if mode != .accurate { socket = try await provider.stream(request) }
        guard token == generation else { await socket?.cancel(); throw CancellationError() }
        try Task.checkCancellation(); try sink.begin(url: recordingURL)
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingOldest(32)); chunks = pair.continuation
        let socket = socket
        feed = Task { [weak self] in
            do {
                for await samples in pair.stream {
                    try Task.checkCancellation()
                    guard let self, self.generation == token else { throw CancellationError() }
                    let bytes = try CloudPolicy.pcm16(samples)
                    guard self.pcm.count + bytes.count <= 16_000 * 2 * 600 else { throw AIProviderError.outputLimit }
                    self.pcm.append(bytes)
                    try await socket?.send(bytes)
                }
            } catch {
                if let self, self.generation == token { self.failure = error; self.onCaptureError?(error.localizedDescription) }
                throw error
            }
        }
        if let socket {
            reader = Task { [weak self] in
                var completed = false
                do {
                    for try await event in socket.events {
                        guard let self, self.generation == token else { throw CancellationError() }
                        switch event {
                        case .partial(let text): self.provisional = text
                        case .final(let value):
                            let segment = CaptionSegment(id: value.id, startSample: value.startSample, endSample: value.endSample, text: value.text, state: .confirmed)
                            if let index = self.confirmed.firstIndex(where: { $0.id == value.id }) { self.confirmed[index] = segment }
                            else { self.confirmed.append(segment) }
                            self.provisional = ""; self.refine(value, token: token)
                        case .completed: completed = true
                        }
                        self.publish()
                    }
                    guard completed else { throw AIProviderError.interrupted }
                } catch {
                    if let self, self.generation == token { self.failure = error; self.onCaptureError?(error.localizedDescription) }
                    throw error
                }
            }
        }
        let mic = MicCapture(inputDeviceUID: microphoneUID)
        let sink = sink
        mic.onChunk = { [weak self] samples in
            do { try sink.append(samples) } catch { Task { @MainActor in guard let self, self.generation == token else { return }; self.failure = error; self.onRecordingError?(error.localizedDescription) }; return }
            if case .dropped = pair.continuation.yield(samples) {
                Task { @MainActor in guard let self, self.generation == token else { return }; self.failure = CloudProcessingError.audioBacklog; self.onCaptureError?(CloudProcessingError.audioBacklog.localizedDescription) }
            }
        }
        mic.onCapture = { [weak self] count, _, peak, error in Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.capturedSeconds += Double(count) / 16000; self.onCapture?(count, peak)
            if let error { self.failure = AIProviderError.interrupted; self.onCaptureError?(error) }
        } }
        capture = mic
        do { try mic.start() } catch { await close(); throw error }
    }
    private func refine(_ segment: AISpeechSegment, token: UUID) {
        guard mode == .hybrid, let refinement, let request = refinementRequest, jobs[segment.id] == nil,
              segment.startSample >= 0, segment.endSample <= pcm.count / 2 else { return }
        let bytes = Self.wav(pcm.subdata(in: segment.startSample * 2..<segment.endSample * 2))
        onSpeech?(.correctionStarted(id: segment.id, audioSeconds: Double(segment.endSample - segment.startSample) / 16000))
        let preceding = latestRefinement
        let task = Task { [weak self] in
            let started = Date()
            do {
                await preceding?.value; try Task.checkCancellation()
                let text = try await refinement.transcribe(bytes, request: request)
                try Task.checkCancellation()
                guard let self, self.generation == token, let index = self.confirmed.firstIndex(where: { $0.id == segment.id }) else { return }
                self.confirmed[index].text = text; self.publish()
                self.onSpeech?(.correctionFinished(id: segment.id, text: text, seconds: Date().timeIntervalSince(started)))
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.onSpeech?(.correctionFailed(id: segment.id, message: error.localizedDescription))
                self.onError?("Accurate recognition failed. The live transcript has been kept.")
            }
        }
        jobs[segment.id] = task; latestRefinement = task
    }
    public func stop() async throws -> String {
        let token = generation
        if let result = capture?.stop() { capturedSeconds = result.durationS }; capture = nil
        chunks?.finish(); chunks = nil; try sink.finish()
        try await feed?.value
        if mode == .accurate {
            let text = try await provider.transcribe(Self.wav(pcm), request: request)
            guard generation == token else { throw CancellationError() }
            confirmed = [.init(id: 1, startSample: 0, endSample: max(1, pcm.count / 2), text: text, state: .confirmed)]; provisional = ""; publish()
        } else {
            let socket = socket
            let deadline = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { await socket?.cancel() } }
            defer { deadline.cancel() }
            try await socket?.finish(); try await reader?.value
        }
        for job in jobs.values { await job.value }
        try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
        if let failure { throw failure }
        guard provisional.isEmpty else { throw AIProviderError.interrupted }
        return confirmed.map(\.text).joined(separator: " ")
    }
    public func close() async {
        generation = UUID(); _ = capture?.stop(); capture = nil; chunks?.finish(); chunks = nil
        feed?.cancel(); reader?.cancel(); for job in jobs.values { job.cancel() }
        await socket?.cancel(); socket = nil; try? sink.finish(); pcm = Data()
        for job in jobs.values { await job.value }
        if let local = refinement as? LocalSpeechFileProvider { await local.close() }
    }
    static func wav(_ pcm: Data) -> Data {
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36)); result.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16)); result.append(Data("data".utf8)); append(UInt32(pcm.count)); result.append(pcm); return result
    }
}
