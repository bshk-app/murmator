import Foundation

/// Which model(s) transcribe an utterance.
public enum DictationMode: String, Sendable, CaseIterable {
    case fast       // Nemotron only — instant draft, no batch final
    case hybrid     // Nemotron live draft + Parakeet batch final
    case accurate   // Parakeet batch only — no live draft
}

extension DictationMode {
    /// Languages where Nemotron's streaming preview is unreliable, so the live
    /// draft stays down and only the Parakeet batch runs.
    ///
    /// This is a property of the fast model, not of the language's difficulty:
    /// on these five it emits confident wrong tokens that the corrector then
    /// has to overwrite, and an empty screen for a moment beats text that
    /// rewrites itself under the reader. Ported from the routing matrix in
    /// dictator's `shared/catalog.py` (`NO_FAST_LOOP`), which measured it.
    ///
    /// Written as language codes without regions: the picker offers `zh` and
    /// `zh-Hans` for one prompt id, and both must gate the same way.
    /// Whisper-only languages join them: Nemotron's preview was never measured on
    /// them, so they get the batch transcript without a draft.
    public static let languagesWithoutLiveDraft: Set<String> = Set([
        "ar", "ja", "ko", "zh", "vi",
    ]).union(SpeechModelChoice.whisperLanguages)

    /// Whether this language may run the fast lane at all.
    public static func allowsLiveDraft(language: String?) -> Bool {
        guard let language else { return true }
        // "auto" cannot be gated: the language is not known until the model has
        // already produced text, so gating it would disable the live draft for
        // everyone. The risk is accepted and confined to automatic detection.
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return !languagesWithoutLiveDraft.contains(base.lowercased())
    }

    /// The mode that will actually run for `language`.
    ///
    /// Downgrades rather than refuses: a user who asked for Hybrid in Japanese
    /// wants dictation, and `.accurate` is the same transcript without the
    /// misleading preview. `.fast` has no batch lane to fall back to, so it
    /// becomes `.accurate` too.
    public func effective(for language: String?) -> DictationMode {
        guard !DictationMode.allowsLiveDraft(language: language) else { return self }
        switch self {
        case .fast, .hybrid: return .accurate
        case .accurate: return .accurate
        }
    }

    /// Longest a live epoch may run without a pause before it is cut.
    ///
    /// In continuous speech the cut lands inside a word. Hybrid and Accurate
    /// re-transcribe each cut phrase with the batch model, so the Core ML batch
    /// path can afford short phrases. Fast has no batch pass to repair the word,
    /// so it takes the longest bound the live lane already runs with.
    public func maxEpochSeconds(batchUsesGPU: Bool) -> Double {
        self == .fast || batchUsesGPU ? 28 : 4
    }

    /// Modes worth offering for `language`; the picker should not show a choice
    /// that silently becomes another one.
    public static func available(for language: String?) -> [DictationMode] {
        allowsLiveDraft(language: language) ? allCases : [.accurate]
    }
}

