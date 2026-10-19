import Foundation

/// Projects text edits onto existing coarse audio spans. It never invents
/// word timestamps: changed/merged words are assigned to the nearest old span.
enum TranscriptTextAlignment {
    static func parts(_ edited: String, matching originals: [String], separator: String = " ") -> [String] {
        guard originals.count > 1 else { return originals.isEmpty ? [] : [edited] }
        func tokens(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
        func key(_ token: Substring) -> String {
            let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let letters = folded.filter { $0.isLetter || $0.isNumber }
            return letters.isEmpty ? folded : letters
        }
        let original = originals.joined(separator: separator)
        let old = tokens(original), new = tokens(edited)
        let difference = new.map(key).difference(from: old.map(key))
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let anchors = Array(zip(old.indices.filter { !removed.contains($0) },
                                new.indices.filter { !inserted.contains($0) }))
        var cuts = [edited.startIndex]
        var oldBoundary = 0, anchor = 0, previousNewBoundary = 0
        for part in originals.dropLast() {
            oldBoundary += tokens(part).count
            while anchor < anchors.count, anchors[anchor].0 < oldBoundary { anchor += 1 }
            let left = anchor > 0 ? anchors[anchor - 1] : (-1, -1)
            let right = anchor < anchors.count ? anchors[anchor] : (old.count, new.count)
            let oldStart = left.0 + 1, newStart = left.1 + 1
            let oldGap = right.0 - oldStart, newGap = right.1 - newStart
            let mapped: Int
            if oldBoundary == right.0 || oldGap <= 0 { mapped = right.1 }
            else { mapped = newStart + Int((Double(oldBoundary - oldStart) * Double(newGap) / Double(oldGap)).rounded()) }
            let boundary = max(previousNewBoundary, min(new.count, max(0, mapped)))
            cuts.append(boundary < new.count ? new[boundary].startIndex : edited.endIndex)
            previousNewBoundary = boundary
        }
        cuts.append(edited.endIndex)
        return zip(cuts, cuts.dropFirst()).map { edited[$0..<$1].trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
