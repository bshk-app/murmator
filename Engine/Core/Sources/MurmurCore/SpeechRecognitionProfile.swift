import Foundation

/// Source-language routing shared by the phone and qualification hosts.
/// An evidence identifier is a reference to an externally audited gate result,
/// not a claim that this value type can validate benchmark evidence itself.
public struct QualifiedSpeechOverride {
    public let language: String
    public let model: SpeechModelChoice
    public let evidenceSHA256: String
    public let device: String
    public init(language: String, model: SpeechModelChoice, evidenceSHA256: String, device: String) {
        self.language = language; self.model = model
        self.evidenceSHA256 = evidenceSHA256; self.device = device
    }
    fileprivate var hasEvidenceReference: Bool {
        evidenceSHA256.count == 64 && evidenceSHA256.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public struct SpeechRecognitionProfile {
    public enum PreviewBackend: String { case nemotron, whistle }
    public enum Origin: String { case baseline, explicitChoice, qualifiedOverride, experimentalCandidate }
    public enum ProfileError: Error { case unsupportedLanguage, unavailableRuntime }
    public let language: String
    public let mode: DictationMode
    public let model: SpeechModelChoice
    public let origin: Origin
    public let evidenceSHA256: String?
    public let previewBackend: PreviewBackend
    public var previewStage: String? { mode == .accurate ? nil : previewBackend == .whistle ? "whistle-swift-cpu" : "nemotron-3.5-asr-streaming-0.6b-8bit" }
    public var finalStage: String? { mode == .fast ? nil : model.rawValue }
    public var independentCorrector: Bool { mode == .hybrid && model.usesGPU }
    public var configurationID: String {
        "\(mode.rawValue):\(model.rawValue):\(language):\(origin.rawValue):\(evidenceSHA256 ?? "baseline"):\(previewBackend.rawValue)"
    }
    public var diagnostics: [String: String] {
        ["language": language, "preview": previewStage ?? "disabled", "final": finalStage ?? "disabled",
         "origin": origin.rawValue, "evidenceSHA256": evidenceSHA256 ?? "none",
         "execution": independentCorrector ? "independent" : "standard"]
    }
    public static var currentDeviceIdentifier: String {
        #if os(iOS) && !targetEnvironment(simulator)
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        #else
        return "other"
        #endif
    }
    public static func baselineModel(language: String) -> SpeechModelChoice {
        // Desktop automatic recognition historically uses multilingual Parakeet.
        // "auto" is a recognition mode, not a language to route to Whisper.
        if language == "auto" { return .parakeet }
        if language == "ru" { return .gigaam }
        if language == "ar" { return .cohereArabic }
        return SpeechModelChoice.parakeet.supports(language) ? .parakeet : .whisper
    }
    /// Keeps a chosen model that can recognize the language, else falls back to its baseline.
    public static func model(_ current: SpeechModelChoice, for language: String) -> SpeechModelChoice {
        current.supports(language) ? current : baselineModel(language: language)
    }
    /// Old versions persisted recommendations and user selections in one field.
    /// A saved recommendation stays automatic; a non-default choice is retained.
    public static func selectionIsExplicit(savedFlag: Bool?, savedModel: SpeechModelChoice?, language: String) -> Bool {
        if let savedFlag { return savedFlag }
        guard let savedModel else { return false }
        return savedModel != baselineModel(language: language)
    }
    public static func resolve(language: String, mode: DictationMode,
                               explicitChoice: SpeechModelChoice? = nil,
                               qualifiedOverrides: [QualifiedSpeechOverride] = [],
                               enableQualifiedOverrides: Bool = false,
                               previewBackend requestedPreview: PreviewBackend = .nemotron,
                               device: String = SpeechRecognitionProfile.currentDeviceIdentifier) throws -> Self {
        let effective = mode.effective(for: language)
        // The CPU path is measured only for English Fast on Mac and is opt-in.
        #if os(macOS)
        let preview: PreviewBackend = requestedPreview == .whistle && language == "en" && effective == .fast ? .whistle : .nemotron
        #else
        let preview: PreviewBackend = .nemotron
        #endif
        if let explicitChoice {
            guard explicitChoice.supports(language) else { throw ProfileError.unsupportedLanguage }
            return .init(language: language, mode: effective, model: explicitChoice, origin: .explicitChoice, evidenceSHA256: nil, previewBackend: preview)
        }
        let matching = qualifiedOverrides.filter {
            LanguagePair.qualityLanguages.contains(language) && $0.language == language && $0.device == device && $0.hasEvidenceReference && $0.model.supports(language)
        }
        // Conflicting catalog entries fail closed to baseline rather than choosing
        // by incidental array order. Disabled experiments never affect defaults.
        if enableQualifiedOverrides, matching.count == 1, let item = matching.first {
            return .init(language: language, mode: effective, model: item.model, origin: .qualifiedOverride, evidenceSHA256: item.evidenceSHA256, previewBackend: preview)
        }
        return .init(language: language, mode: effective, model: baselineModel(language: language), origin: .baseline, evidenceSHA256: nil, previewBackend: preview)
    }
    /// Benchmark-only entrypoint. Candidate profiles cannot enter the override
    /// table without a separately reviewed evidence reference.
    public static func candidate(language: String, mode: DictationMode, runtimeID: String) throws -> Self {
        guard let model = SpeechModelChoice(rawValue: runtimeID) else { throw ProfileError.unavailableRuntime }
        guard model.supports(language) else { throw ProfileError.unsupportedLanguage }
        return .init(language: language, mode: mode.effective(for: language), model: model, origin: .experimentalCandidate, evidenceSHA256: nil, previewBackend: .nemotron)
    }
}
