import MurmurCore
import Foundation
import MurmurMT

/// On-device translation of a committed utterance.
///
/// The engine is bergamot-translator running on the CPU, which is the whole
/// reason it can exist alongside dictation: Nemotron and Parakeet already hold
/// the GPU under `TwoTierEngine`'s 60% memory cap, and the two-line mode
/// translates *while* they are transcribing rather than instead of them.
///
/// Measured on FLORES+ devtest, a 15-second utterance costs about 30 ms per
/// segment on an M-series machine — two orders of magnitude inside the budget
/// that matters, which is why translation is allowed to be synchronous here.
///
/// Not `Sendable`: one instance owns one loaded model and one non-reentrant
/// C++ service. `TranslationService` owns the serialisation.
public final class Translator: TextTranslating {
    public enum Failure: Error, CustomStringConvertible, LocalizedError {
        case modelUnavailable(pair: LanguagePair, path: String)
        case engine(String)

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case let .modelUnavailable(pair, path):
                return "no translation model for \(pair) at \(path)"
            case let .engine(message):
                return "translation engine: \(message)"
            }
        }
    }

    private let handle: OpaquePointer
    public let pair: LanguagePair

    /// Loads the model for `pair` from `modelsRoot`. Loading is eager and takes
    /// roughly 150 ms, including the first forward pass: Marian builds its
    /// graph lazily, so a caller that skipped the warm-up would charge graph
    /// construction to the first thing the user said.
    public init(pair: LanguagePair, modelsRoot: URL) throws {
        let directory = modelsRoot.appendingPathComponent(pair.modelDirectoryName)
        let config = directory.appendingPathComponent("config.bergamot.yml")
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw Failure.modelUnavailable(pair: pair, path: directory.path)
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let opened = murmur_mt_open(config.path, &error) else {
            defer { if let error { murmur_mt_string_free(error) } }
            throw Failure.engine(error.map { String(cString: $0) } ?? "could not open model")
        }
        // An opaque C struct arrives in Swift as OpaquePointer already.
        self.handle = opened
        self.pair = pair
    }

    deinit { murmur_mt_close(handle) }

    /// Translates one committed utterance. Empty input yields empty output —
    /// a segment the recogniser found no words in is not an error.
    public func translate(_ text: String) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let out = murmur_mt_translate(handle, text, &error) else {
            defer { if let error { murmur_mt_string_free(error) } }
            throw Failure.engine(error.map { String(cString: $0) } ?? "translation failed")
        }
        defer { murmur_mt_string_free(out) }
        return String(cString: out)
    }
}
