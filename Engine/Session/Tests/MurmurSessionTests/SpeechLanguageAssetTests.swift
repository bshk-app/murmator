import Foundation
import XCTest
@testable import MurmurSpeech

final class SpeechLanguageAssetTests: XCTestCase {
    func testTokenizerInstallationFollowsSnapshotLinksAndRepairsDanglingCopies() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("murmur-tokenizer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let sourceRepo = root.appendingPathComponent("tokenizer-repo")
        let snapshot = sourceRepo.appendingPathComponent("snapshots/revision")
        let blobs = sourceRepo.appendingPathComponent("blobs")
        let destination = root.appendingPathComponent("whisper-repo/snapshots/revision/openai_whisper-base/tokenizer.json")
        for directory in [snapshot, blobs, destination.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = Data(#"{"tokenizer":"fixture"}"#.utf8)
        let blob = blobs.appendingPathComponent("tokenizer-blob")
        try payload.write(to: blob)
        let source = snapshot.appendingPathComponent("tokenizer.json")
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "../../blobs/tokenizer-blob")

        // Reproduce the old installation: the copied relative link is dangling
        // inside a different repository and an extra directory level.
        try fm.copyItem(at: source, to: destination)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), "../../blobs/tokenizer-blob")

        try SpeechLanguageDetector.installTokenizerFile(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertThrowsError(try fm.destinationOfSymbolicLink(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.path), "../../blobs/tokenizer-blob")
    }
}
