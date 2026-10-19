import DictatorCore
import Foundation
import MurmurCore

/// Maps server segment identities into the existing durable note representation.
public struct CloudTranscript: Sendable {
    public private(set) var transcript = RecordingTranscript()
    public private(set) var confirmed: [CaptionSegment] = []
    public private(set) var provisional = ""
    public private(set) var revision: UInt64 = 0
    public private(set) var translated: [UtteranceTranslation] = []
    public init() {}
    public var snapshot: CaptionSnapshot {
        .init(revision: revision, confirmed: confirmed, provisional: provisional)
    }

    public mutating func accept(_ event: StreamEvent, capturedSamples: Int) {
        switch event.type {
        case .partial, .fast: provisional = event.text ?? ""
        case .final:
            guard let segment = event.segment, segment >= 0, let text = event.text else { return }
            let id = UInt64(segment) + 1
            let start = event.startSample ?? confirmed.last?.endSample ?? 0
            let end = event.endSample ?? max(start + 1, capturedSamples)
            let value = CaptionSegment(id: id, startSample: start, endSample: end, text: text, state: .confirmed)
            if let index = confirmed.firstIndex(where: { $0.id == id }) {
                confirmed[index] = value
            } else {
                confirmed.append(value)
            }
            provisional = ""
        case .translation, .translationError:
            guard let segment = event.segment, segment >= 0,
                  let source = confirmed.first(where: { $0.id == UInt64(segment) + 1 }) else { return }
            let value = UtteranceTranslation(id: source.id, source: source.text, text: event.translation ?? "", isFinal: true, failed: event.type == .translationError)
            translated.removeAll { $0.id == value.id }; translated.append(value)
            transcript.applyTranslations([value]); return
        default: return
        }
        revision &+= 1
        _ = transcript.apply(snapshot)
    }

    public mutating func finish(samples: Int) {
        transcript.finish(fallback: transcript.text, endSample: samples)
    }
}
