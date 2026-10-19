import Foundation
import MurmurCore
import MurmurSpeech
import AIProvidersCore

/// Local accurate recognition behind the same file contract as cloud models.
/// This keeps "Local" meaningful when the live lane is a cloud provider.
struct LocalSpeechFileProvider: AISpeechProviding {
    private let lane: CoreMLSpeechLane
    init(choice: SpeechModelChoice, modelsRoot: URL) { lane = CoreMLSpeechLane(choice: choice, modelsRoot: modelsRoot) }
    func prepare() async throws { try await lane.load() }
    func close() async { await lane.close() }
    func transcribe(_ audio: Data, request: AISpeechRequest) async throws -> String {
        guard audio.count >= 44, audio.prefix(4) == Data("RIFF".utf8), (audio.count - 44) % 2 == 0, request.sampleRate == 16000 else { throw AIProviderError.invalidResponse }
        var samples: [Float] = []; samples.reserveCapacity((audio.count - 44) / 2)
        audio.withUnsafeBytes { bytes in
            for offset in stride(from: 44, to: bytes.count, by: 2) {
                samples.append(Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768)
            }
        }
        try Task.checkCancellation()
        return try await lane.transcribe(samples, language: request.language == "auto" ? nil : request.language)
    }
}
