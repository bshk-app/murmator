import Foundation
import os

/// Retention for the diagnostic utterance recordings.
///
/// These files are the user's own speech, so "keep everything forever in Caches"
/// is not a defensible default: the setting that produces them promises a bounded
/// window, and this is where that promise is kept.
public enum DiagnosticRecordings {
    public static let directoryName = "Murmur"
    public static let filePrefix = "utterance-"
    /// Enough history to reproduce a complaint, not enough to become an archive.
    public static let keepNewest = 20
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let modified: Date
        public init(url: URL, modified: Date) {
            self.url = url
            self.modified = modified
        }
    }

    /// Which recordings must go: anything past the age limit, plus anything beyond
    /// the newest `keepNewest`. Pure so the rule can be tested without a disk.
    public static func expired(
        _ entries: [Entry],
        now: Date,
        keepNewest: Int = keepNewest,
        maxAge: TimeInterval = maxAge
    ) -> [Entry] {
        let newestFirst = entries.sorted { $0.modified > $1.modified }
        var victims: [Entry] = []
        for (index, entry) in newestFirst.enumerated() {
            let tooOld = now.timeIntervalSince(entry.modified) > maxAge
            let tooMany = index >= max(0, keepNewest)
            if tooOld || tooMany { victims.append(entry) }
        }
        return victims
    }

    public static func directory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Delete what `expired` selects. Failures are reported and skipped: a locked
    /// file must not stop the sweep, and must not fail the dictation that ran it.
    @discardableResult
    public static func sweep(directory url: URL = directory(), now: Date = Date()) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        let entries: [Entry] = names.compactMap { file in
            guard file.lastPathComponent.hasPrefix(filePrefix) else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return Entry(url: file, modified: date ?? .distantPast)
        }
        var removed = 0
        for victim in expired(entries, now: now) {
            do {
                try manager.removeItem(at: victim.url)
                removed += 1
            } catch {
                Logger(subsystem: "app.bshk.murmur", category: "diagnostic-audio").error("Could not remove diagnostic audio: domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
            }
        }
        return removed
    }

    /// Remove every recording now — what "turn it off" and "delete" both mean.
    @discardableResult
    public static func deleteAll(directory url: URL = directory()) -> Int {
        sweep(directory: url, now: .distantFuture)
    }

    /// How many recordings are on disk — what a confirmation prompt must state
    /// before it offers to destroy them.
    public static func count(directory url: URL = directory()) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return 0 }
        return names.filter { $0.hasPrefix(filePrefix) }.count
    }
}
