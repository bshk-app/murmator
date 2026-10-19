@_exported import DictatorAppleAuth
@_exported import DictatorCore
import Foundation
import MurmurCore

public enum ProcessingLocation: String, Codable, Sendable { case device, cloud }
public enum CloudProcessingError: Error, LocalizedError, Sendable {
    case signInRequired, insufficientCredits, unavailableLanguage, unavailableTranslation, inputTooLong(Int), busy, audioBacklog, interrupted, finalizationTimeout, incompleteTranscript
    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to your cloud account first."
        case .insufficientCredits: "Not enough cloud credits."
        case .unavailableLanguage: "Cloud transcription is unavailable for this language."
        case .unavailableTranslation: "Cloud translation is unavailable for these languages."
        case let .inputTooLong(maximum): "Cloud translation accepts up to \(maximum) source characters."
        case .busy: "Finish the current cloud operation first."
        case .audioBacklog: "The connection cannot keep up with recording. Your captured audio is kept."
        case .interrupted: "The cloud request was interrupted. It may have completed; it will not be retried automatically."
        case .finalizationTimeout: "Cloud processing timed out. Your original audio and received text are kept."
        case .incompleteTranscript: "Some audio could not be transcribed. Your original audio and received text are kept."
        }
    }
}

public enum CloudPolicy {
    public static func tier(_ mode: DictationMode) -> Tier {
        switch mode { case .fast: .fast; case .accurate: .quality; case .hybrid: .hybrid }
    }

    public static func translationTargets(_ capabilities: Capabilities?, source: String, transcript: Bool = false) -> [String] {
        guard let policy = capabilities?.translation, policy.enabled,
              transcript ? policy.transcriptMode == "included" || policy.transcriptCreditsPer1000 != nil : policy.textCreditsPer1000 != nil else { return [] }
        return policy.pairs.filter { $0.source == source }.map(\.target).sorted()
    }

    public static func pcm16(_ samples: [Float]) throws -> Data {
        guard samples.allSatisfy(\.isFinite) else { throw DictatorError.invalidAudio }
        let values = samples.map { Int16(max(-32768, min(32767, Int((max(-1, min(1, $0)) * 32768).rounded())))).littleEndian }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func message(_ error: Error) -> String {
        if let value = error as? CloudProcessingError {
            return value.errorDescription ?? "Cloud processing failed."
        }
        if let value = error as? DictatorError {
            switch value {
            case .unauthorized: return "Your cloud session expired. Sign in again."
            case .insufficientCredits: return "Not enough cloud credits."
            case .readinessTimeout: return "Cloud startup timed out. Your audio has not been sent."
            case .unavailable: return "The cloud service is unavailable. Please try again later."
            case let .rejected(_, message): return message
            default: return "Cloud processing failed. Your original audio and text are kept."
            }
        }
        if error is URLError {
            return "Check your internet connection. Your original audio and text are kept."
        }
        return error.localizedDescription
    }
}
