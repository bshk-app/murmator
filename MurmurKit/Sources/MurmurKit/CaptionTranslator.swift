import Foundation

/// Keeps a running translation of a caption transcript.
///
/// Captions differ from dictation in what can be translated and when. A
/// dictation is translated once, at stop, because there is exactly one final
/// text. A caption session emits a new snapshot every time the draft moves —
/// several times a second, for the length of a talk — so translating the whole
/// transcript on each one would re-translate the same sentences hundreds of
/// times and saturate the core the engine runs on.
///
/// So only *closed* phrases are translated, and each one only when its text is
/// new. The live draft is deliberately left out: it is rewritten on nearly
/// every snapshot, and a second line flickering through half-formed sentences
/// is harder to read than one that trails slightly behind.
/// The one thing `CaptionTranslator` needs from the engine.
///
/// A protocol so the caching and correction rules below can be tested without
/// 17 MB of models on disk: they are where this type can silently go wrong,
/// and an untestable cache is how stale translations survive a correction.
public protocol PhraseTranslating: Sendable {
    func translateOrEmpty(_ text: String, from source: String, to target: String) async -> String
    /// Only successful results may enter the caption cache, including "".
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

private enum PhraseTranslationFailure: Error { case unavailable }

public extension PhraseTranslating {
    /// Compatibility for best-effort engines that do not expose their errors.
    /// Such an engine cannot distinguish empty output from failure; implement
    /// `translate` to preserve successful empty results in the cache.
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let result = await translateOrEmpty(text, from: source, to: target)
        guard !result.isEmpty else { throw PhraseTranslationFailure.unavailable }
        return result
    }
}

extension TranslationService: PhraseTranslating {}

public actor CaptionTranslator {
    private let service: any PhraseTranslating
    /// Actor isolation does not prevent an old await from resuming after reset.
    private var generation = UUID()
    /// Keyed by segment id, holding its exact text and language pair. Neither
    /// a batch correction nor a language switch may reuse an old translation.
    private var done: [UInt64: (source: String, pair: LanguagePair, translated: String)] = [:]
    /// The live tail, cached by its exact text and language pair. The draft is
    /// rewritten far more often than it actually changes wording, and
    /// re-translating an identical string would burn the core for nothing.
    private var draftCache: (source: String, pair: LanguagePair, translated: String)?

    public init(service: any PhraseTranslating) {
        self.service = service
    }

    /// Translation of every closed phrase, in order.
    ///
    /// Returns "" when nothing has closed yet, which reads on screen as a HUD
    /// with no second line rather than an empty one.
    /// - Parameter draft: the live tail. Passing it on translates speech as it
    ///   is still being said, at the cost of a line that rewrites itself: a
    ///   half-spoken sentence has a different translation from the finished one,
    ///   and machine translation of a fragment is often confidently wrong.
    ///   Passing "" keeps the second line to settled phrases only.
    public func translation(of segments: [CaptionSegment],
                            draft: String = "",
                            from source: String,
                            to target: String) async -> String {
        let token = generation
        let pair = LanguagePair(source: source, target: target)
        // Anything the transcript dropped is gone for good; without this the
        // map grows for the whole talk.
        let liveIDs = Set(segments.map(\.id))
        done = done.filter { liveIDs.contains($0.key) }

        var out: [String] = []
        out.reserveCapacity(segments.count)

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let cached = done[segment.id], cached.source == text, cached.pair == pair {
                out.append(cached.translated)
                continue
            }
            // Cancellation matters here: a talk can close many phrases at once
            // after a pause, and the session may end mid-way through them.
            if Task.isCancelled { break }

            let translated = try? await service.translate(text, from: source, to: target)
            guard generation == token, !Task.isCancelled else { return "" }
            if let translated {
                done[segment.id] = (source: text, pair: pair, translated: translated)
                out.append(translated)
            }
        }

        let tail = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, !Task.isCancelled {
            if let cached = draftCache, cached.source == tail, cached.pair == pair {
                out.append(cached.translated)
            } else {
                let translated = try? await service.translate(tail, from: source, to: target)
                guard generation == token, !Task.isCancelled else { return "" }
                if let translated {
                    draftCache = (source: tail, pair: pair, translated: translated)
                    out.append(translated)
                }
            }
        }

        return out.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Forget everything — a new talk starts with an empty second line.
    public func reset() {
        generation = UUID()
        done.removeAll()
        draftCache = nil
    }
}
