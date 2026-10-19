import Foundation
import MLX
import MurmurCore
import MurmurPostProcessing

/// Reproducible, opt-in model smoke/qualification runner; never opens a microphone.
/// Usage: text-edit-probe fixtures.json [model ID or LocalTextModel raw value]
@main struct TextEditProbe {
    struct Fixture: Decodable { let id: String; let language: String; let text: String; let reference: String }
    struct Row: Encodable {
        let id: String, language: String, input: String, reference: String
        let output: String?, model: String?, error: String?, seconds: Double
        let candidate: String?
    }
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 || arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: text-edit-probe fixtures.json [model]\n".utf8))
            return
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        GPU.set(memoryLimit: Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.5), relaxed: false)
        let candidate = CandidateBox()
        let editor = LocalTranscriptEditor { candidate.set($0.text) }
        var rows: [Row] = []
        let checkpoint = ProcessInfo.processInfo.environment["MURMUR_TEXT_BENCH_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for fixture in fixtures {
            candidate.set(nil)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let result = try await editor.edit(.init(text: fixture.text, language: fixture.language,
                                                       modelID: arguments.count == 2 ? arguments[1] : nil))
                rows.append(.init(id: fixture.id, language: fixture.language, input: fixture.text, reference: fixture.reference,
                    output: result.text, model: result.modelID, error: nil, seconds: ProcessInfo.processInfo.systemUptime - start,
                    candidate: candidate.get()))
            } catch {
                rows.append(.init(id: fixture.id, language: fixture.language, input: fixture.text, reference: fixture.reference,
                    output: nil, model: LocalTextModel.resolve(language: fixture.language, modelID: arguments.count == 2 ? arguments[1] : nil).repository,
                    error: String(describing: error), seconds: ProcessInfo.processInfo.systemUptime - start,
                    candidate: candidate.get()))
            }
            if let checkpoint { try encoder.encode(rows).write(to: checkpoint, options: .atomic) }
            FileHandle.standardError.write(Data("\(fixture.id): \(rows.last?.error ?? "completed")\n".utf8))
        }
        await editor.unload()
        print(String(decoding: try encoder.encode(rows), as: UTF8.self))
    }
}

private final class CandidateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
