import Foundation

/// An edit in the OLD string's UTF-16 coordinates. Apply edits back to front.
public struct CaptionsTextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum CaptionsTextDiff {
    public static func edits(from old: String, to new: String) -> [CaptionsTextEdit] {
        // Trim the shared history before diffing. Boundaries are grapheme-safe;
        // literal UTF-16 equality also distinguishes é from e + combining acute.
        var oldStart = old.startIndex, newStart = new.startIndex
        while oldStart < old.endIndex, newStart < new.endIndex {
            let a = old.index(after: oldStart), b = new.index(after: newStart)
            guard old[oldStart..<a].utf16.elementsEqual(new[newStart..<b].utf16) else { break }
            oldStart = a; newStart = b
        }
        var oldEnd = old.endIndex, newEnd = new.endIndex
        while oldEnd > oldStart, newEnd > newStart {
            let a = old.index(before: oldEnd), b = new.index(before: newEnd)
            guard old[a..<oldEnd].utf16.elementsEqual(new[b..<newEnd].utf16) else { break }
            oldEnd = a; newEnd = b
        }
        let oldMiddle = old[oldStart..<oldEnd], newMiddle = new[newStart..<newEnd]
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }
        let base = oldStart.utf16Offset(in: old)
        let replacement = CaptionsTextEdit(range: NSRange(location: base, length: oldMiddle.utf16.count),
                                          replacement: String(newMiddle))
        // Appends and clears need no alignment. A wholesale replacement of an
        // unusually large transcript must also stay bounded on the main thread.
        guard !oldMiddle.isEmpty, !newMiddle.isEmpty,
              oldMiddle.utf16.count <= 4096, newMiddle.utf16.count <= 4096 else { return [replacement] }
        let before = oldMiddle.map(String.init), after = newMiddle.map(String.init)
        guard before.count * after.count <= 1_000_000 else { return [replacement] }
        let difference = after.difference(from: before) { $0.utf16.elementsEqual($1.utf16) }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var offsets = [base]
        for character in before { offsets.append(offsets.last! + character.utf16.count) }
        var edits: [CaptionsTextEdit] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if removed.contains(i) || inserted.contains(j) {
                let start = i, replacementStart = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                edits.append(CaptionsTextEdit(
                    range: NSRange(location: offsets[start], length: offsets[i] - offsets[start]),
                    replacement: after[replacementStart..<j].joined()
                ))
            } else {
                // A matching island stays in NSTextStorage with its attributes.
                i += 1; j += 1
            }
        }
        return edits
    }
}
