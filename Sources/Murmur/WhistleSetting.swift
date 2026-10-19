import Foundation
import MurmurKit
import class MurmurCloud.ProviderPreferences

enum WhistleSetting {
    static let key = "whistleFastEnabled"
    @MainActor static func profile(language: String, mode: DictationMode) throws -> SpeechRecognitionProfile {
        if ProviderPreferences.shared.selection(.streamingTranscription) != nil, mode != .accurate {
            return .external(language: language, mode: mode)
        }
        return try SpeechRecognitionProfile.resolve(language: language, mode: mode,
            previewBackend: UserDefaults.standard.bool(forKey: key) ? .whistle : .nemotron)
    }
}
