import Foundation

public struct RecordedUtterance: Identifiable, Codable, Hashable, Sendable {
    public let id: UInt64
    public let startSample: Int
    public var endSample: Int
    public var text: String
    public var translation: String?
    public var settled: Bool
    public var translationFailed: Bool?
    public var source: ConversationSource?
    public var sourceID: UUID?
    public var sourceName: String?
    public init(id: UInt64, startSample: Int, endSample: Int, text: String, translation: String? = nil, settled: Bool = false) {
        self.id = id; self.startSample = startSample; self.endSample = endSample
        self.text = text; self.translation = translation; self.settled = settled
    }
}

public struct UtteranceTranslation: Sendable {
    public let id: UInt64
    public let source: String
    public let text: String
    public let isFinal: Bool
    public let failed: Bool
    public init(id: UInt64, source: String, text: String, isFinal: Bool, failed: Bool = false) {
        self.id = id; self.source = source; self.text = text; self.isFinal = isFinal; self.failed = failed
    }
}

/// Durable conversation content is independent of any visible caption window.
/// ASR corrections replace only their covered ranges. Once finished, the text
/// editor can correct the whole transcript while preserving those audio spans.
public struct RecordingTranscript: Sendable {
    public private(set) var utterances: [RecordedUtterance] = []
    public private(set) var provisional = ""
    public private(set) var revision: UInt64 = 0
    private var receivedSnapshot = false
    private var settledBoundary = -1
    private var settledIDs: Set<UInt64> = []
    private var finished = false
    private var finalEditedText: String?
    public init() {}
    public var hasSnapshots: Bool { receivedSnapshot }
    public var text: String { finalEditedText ?? (utterances.map(\.text) + [provisional]).filter { !$0.isEmpty }.joined(separator: " ") }
    public var translatedText: String { utterances.compactMap(\.translation).filter { !$0.isEmpty }.joined(separator: " ") }

    /// Appends one final, nonoverlapping section produced by a serial speech
    /// translator. Repeated text is preserved because it may be real speech.
    public mutating func appendSettled(_ value: RecordedUtterance) {
        guard !finished, !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.endSample > value.startSample,
              value.startSample >= (utterances.last?.endSample ?? 0) else { return }
        var settled = value
        settled.settled = true
        utterances.append(settled)
        settledIDs.insert(settled.id)
        settledBoundary = settled.endSample
        revision &+= 1
        receivedSnapshot = true
    }

    @discardableResult public mutating func apply(_ snapshot: CaptionSnapshot) -> Bool {
        guard !finished, !receivedSnapshot || snapshot.revision > revision || (snapshot.revision == revision && (snapshot.settledThroughSample ?? -1) > settledBoundary) else { return false }
        receivedSnapshot = true; revision = snapshot.revision; provisional = snapshot.provisional
        settledBoundary = max(settledBoundary, snapshot.settledThroughSample ?? -1)
        var changedEntries = false
        for segment in snapshot.confirmed {
            if settledIDs.contains(segment.id) { continue }
            guard let end = segment.endSample, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // A late shorter result cannot restore an ID already covered by a later correction.
            if utterances.contains(where: { $0.id > segment.id && $0.startSample <= segment.startSample && $0.endSample >= end }) { continue }
            if let old = utterances.first(where: { $0.id == segment.id }), old.settled { continue }
            let previous = utterances.first { $0.id == segment.id && $0.text == segment.text }
            utterances.removeAll { !$0.settled && ($0.id == segment.id || ($0.id < segment.id && $0.startSample >= segment.startSample && $0.endSample <= end)) }
            utterances.append(.init(id: segment.id, startSample: segment.startSample, endSample: end,
                                    text: segment.text, translation: previous?.translation,
                                    settled: end <= settledBoundary))
            changedEntries = true
        }
        if changedEntries { utterances.sort { $0.startSample == $1.startSample ? $0.id < $1.id : $0.startSample < $1.startSample } }
        if let boundary = snapshot.settledThroughSample {
            for index in utterances.indices where utterances[index].endSample <= boundary {
                utterances[index].settled = true
                settledIDs.insert(utterances[index].id)
            }
        }
        return true
    }
    public mutating func applyTranslations(_ values: [UtteranceTranslation]) {
        for value in values where value.isFinal {
            guard let index = utterances.firstIndex(where: { $0.id == value.id && $0.text == value.source }) else { continue }
            utterances[index].translation = value.failed ? nil : value.text
            utterances[index].translationFailed = value.failed
        }
    }
    /// Changing the target must not retain old-language results or discard source history.
    public mutating func clearTranslations() {
        for index in utterances.indices {
            utterances[index].translation = nil
            utterances[index].translationFailed = nil
        }
    }
    /// Text editing retains audio ranges, IDs and source metadata. Old translations
    /// cannot survive a changed original, including settled/finalized utterances.
    public mutating func applyTextEdits(_ values: [UInt64: String]) {
        var changed = false
        for index in utterances.indices {
            guard let text = values[utterances[index].id], !text.isEmpty, text != utterances[index].text else { continue }
            utterances[index].text = text
            utterances[index].translation = nil
            utterances[index].translationFailed = nil
            changed = true
        }
        if changed { finalEditedText = nil; revision &+= 1 }
    }
    /// Apply one final whole-transcript correction, retaining IDs, audio spans,
    /// source metadata and the exact corrected text (including paragraph breaks).
    public mutating func applyFinalTextEdit(_ text: String) {
        guard finished, !utterances.isEmpty, !text.isEmpty, text != self.text else { return }
        let parts = TranscriptTextAlignment.parts(text, matching: utterances.map(\.text))
        for index in utterances.indices where parts[index] != utterances[index].text {
            utterances[index].text = parts[index]
            utterances[index].translation = nil
            utterances[index].translationFailed = nil
        }
        finalEditedText = text
        revision &+= 1
    }
    public mutating func finish(fallback: String, endSample: Int) {
        guard !finished else { return }
        if utterances.isEmpty && !fallback.isEmpty {
            utterances = [.init(id: 0, startSample: 0, endSample: endSample, text: fallback, settled: true)]
        } else if !provisional.isEmpty {
            let start = utterances.last?.endSample ?? 0
            utterances.append(.init(id: (utterances.map(\.id).max() ?? 0) + 1, startSample: start,
                                    endSample: max(start, endSample), text: provisional, settled: true))
        }
        for index in utterances.indices { utterances[index].settled = true; settledIDs.insert(utterances[index].id) }
        provisional = ""; finished = true
    }
}
