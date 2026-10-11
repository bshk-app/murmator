import Foundation
import Darwin
import CryptoKit
import MurmurCore
import MurmurSpeech
import MurmurSession

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
struct FailureRecord: Codable { let seconds: Double; let message: String }
struct MetricSample: Codable { let seconds: Double; let speech: SpeechQualificationSnapshot }
struct Report: Codable {
    let source: String
    let target: String?
    let wav: String
    let inputFileSHA256: String
    let replayAudioSHA256: String
    let audioSeconds: Double
    var status = "preparing"
    var speechProfile: [String: String] = [:]
    var utterances: [RecordedUtterance] = []
    var preparationSeconds: Double?
    var wallSeconds = 0.0
    var firstSnapshotSeconds: Double?
    var firstSnapshotText: String?
    var firstTranslationSeconds: Double?
    var snapshotCount = 0
    var translationCount = 0
    var finalText = ""
    var finalTranslation = ""
    var capturedSeconds = 0.0
    var failures: [FailureRecord] = []
    var metrics: [MetricSample] = []
    var latestSpeechTelemetry: SpeechQualificationSnapshot?
    var processPeakRSSBytes: Int?
    var speechComputeSeconds: Double?
    var speechReplayWallSeconds: Double?
    var replayCPUSeconds: Double?
}

func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

func readWAV(_ data: Data) throws -> [Float] {
    func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func tag(_ at: Int) -> String { String(decoding: data[at..<at + 4], as: UTF8.self) }
    guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw ProbeError("Expected RIFF WAV") }
    var validFormat = false
    var pcm: Range<Int>?
    var offset = 12
    while offset + 8 <= data.count {
        let size = Int(u32(offset + 4)), start = offset + 8
        guard size <= data.count - start else { throw ProbeError("Truncated WAV chunk") }
        if tag(offset) == "fmt " {
            guard size >= 16 else { throw ProbeError("Invalid WAV format") }
            validFormat = u16(start) == 1 && u16(start + 2) == 1 && u32(start + 4) == 16_000 && u16(start + 14) == 16
        }
        if tag(offset) == "data" { pcm = start..<start + size }
        offset = start + size + size % 2
    }
    guard validFormat, let pcm, !pcm.isEmpty, pcm.count % 2 == 0 else { throw ProbeError("Use nonempty 16 kHz mono PCM16 WAV") }
    return stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map { Float(Int16(bitPattern: u16($0))) / 32_768 }
}

@main struct SessionProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("session-probe: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        var args: [String: String] = [:]
        let values = Array(CommandLine.arguments.dropFirst())
        if values == ["--help"] {
            print("session-probe --wav PCM16.wav --models-root PATH --translation-root PATH --output report.json [--seconds N] [--source ru] [--target en|none] [--mode hybrid|fast|accurate]")
            return
        }
        guard values.count % 2 == 0 else { throw ProbeError("Options require values; use --help") }
        let options: Set<String> = ["--wav", "--models-root", "--translation-root", "--output", "--seconds", "--source", "--target", "--mode"]
        for index in stride(from: 0, to: values.count, by: 2) {
            guard options.contains(values[index]), args[values[index]] == nil else { throw ProbeError("Unknown or duplicate option \(values[index])") }
            args[values[index]] = values[index + 1]
        }
        func required(_ key: String) throws -> String {
            guard let value = args[key], !value.isEmpty else { throw ProbeError("Missing \(key)") }; return value
        }
        let wav = try required("--wav"), output = URL(fileURLWithPath: try required("--output"))
        let models = URL(fileURLWithPath: try required("--models-root"))
        let translation = URL(fileURLWithPath: try required("--translation-root"))
        let source = args["--source"] ?? "ru", rawTarget = args["--target"] ?? "en"
        let target = rawTarget == "none" ? nil : rawTarget
        guard let mode = DictationMode(rawValue: args["--mode"] ?? "hybrid") else { throw ProbeError("Invalid mode") }
        let data = try Data(contentsOf: URL(fileURLWithPath: wav)), original = try readWAV(data)
        var samples = original
        if let rawSeconds = args["--seconds"] {
            guard let seconds = Double(rawSeconds), seconds.isFinite, seconds > 0, seconds <= 86_400 else { throw ProbeError("--seconds must be in (0, 86400]") }
            let count = Int(seconds * 16_000)
            let cycle = original + Array(repeating: Float.zero, count: 32_000)
            samples = (0..<count).map { cycle[$0 % cycle.count] }
        }
        let audioHash = samples.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        var report = Report(source: source, target: target, wav: wav,
            inputFileSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            replayAudioSHA256: audioHash, audioSeconds: Double(samples.count) / 16_000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write() throws { try encoder.encode(report).write(to: output, options: .atomic) }
        try write()
        let session = RecordingSession(modelsRoot: models, translationRoot: translation,
            memoryLimit: min(Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.45), 3_500_000_000))
        let began = ProcessInfo.processInfo.systemUptime
        var recordingBegan: Double?
        var lastMetric = -Double.infinity
        session.onEvent = { event in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - (recordingBegan ?? began)
            switch event {
            case .snapshot(let value):
                report.snapshotCount += 1
                if report.firstSnapshotSeconds == nil, !value.provisional.isEmpty || !value.confirmed.isEmpty {
                    report.firstSnapshotSeconds = elapsed
                    report.firstSnapshotText = (value.confirmed.map(\.text) + [value.provisional])
                        .filter { !$0.isEmpty }.joined(separator: " ")
                }
            case .translation(let text, _):
                report.translationCount += 1
                if report.firstTranslationSeconds == nil, !text.isEmpty { report.firstTranslationSeconds = elapsed }
            case .telemetry(let value):
                report.latestSpeechTelemetry = value
                if elapsed - lastMetric >= 1 { report.metrics.append(.init(seconds: elapsed, speech: value)); lastMetric = elapsed }
            case .failure(let value): report.failures.append(.init(seconds: elapsed, message: String(describing: value)))
            default: break
            }
        }
        let checkpoint = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                report.wallSeconds = ProcessInfo.processInfo.systemUptime - began
                report.finalText = session.transcript.text
                report.finalTranslation = session.transcript.translatedText
                report.capturedSeconds = session.capturedSeconds
                do { try write() } catch { FileHandle.standardError.write(Data("checkpoint: \(error)\n".utf8)) }
            }
        }
        defer { checkpoint.cancel() }
        do {
            let preview: SpeechRecognitionProfile.PreviewBackend = ProcessInfo.processInfo.environment["MURMUR_WHISTLE_CPU"] == "1" ? .whistle : .nemotron
            let profile = try SpeechRecognitionProfile.resolve(language: source, mode: mode, previewBackend: preview)
            report.speechProfile = profile.diagnostics
            try await session.prepare(.init(profile: profile, target: target))
            report.preparationSeconds = ProcessInfo.processInfo.systemUptime - began
            report.status = "replaying"; try write()
            recordingBegan = ProcessInfo.processInfo.systemUptime
            let cpuBegan = processCPUSeconds()
            let result = try await session.replayRealtimeForQualification(samples)
            report.replayCPUSeconds = processCPUSeconds() - cpuBegan
            report.speechComputeSeconds = session.lastQualificationReplay?.computeSeconds
            report.speechReplayWallSeconds = session.lastQualificationReplay?.wallSeconds
            report.finalText = result.text; report.finalTranslation = result.translation
            report.utterances = result.transcript.utterances
            report.capturedSeconds = result.duration; report.status = report.failures.isEmpty ? "completed" : "completed-with-failures"
        } catch {
            report.status = "failed"
            report.failures.append(.init(seconds: ProcessInfo.processInfo.systemUptime - (recordingBegan ?? began), message: String(describing: error)))
            report.finalText = session.transcript.text; report.finalTranslation = session.transcript.translatedText
            report.capturedSeconds = session.capturedSeconds
            report.wallSeconds = ProcessInfo.processInfo.systemUptime - began
            try write(); await session.unload(); throw error
        }
        report.wallSeconds = ProcessInfo.processInfo.systemUptime - began
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { report.processPeakRSSBytes = usage.ru_maxrss }
        try write(); await session.unload()
        print(output.path)
    }
}
