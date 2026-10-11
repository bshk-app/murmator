import Foundation
import MurmurKit

enum WhistleSetting {
    static let key = "whistleFastEnabled"
    static func profile(language: String, mode: DictationMode) throws -> SpeechRecognitionProfile {
        try SpeechRecognitionProfile.resolve(language: language, mode: mode,
            previewBackend: UserDefaults.standard.bool(forKey: key) ? .whistle : .nemotron)
    }
}
