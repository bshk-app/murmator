import XCTest
@testable import MurmurCore

final class RecordingPersistenceTests: XCTestCase {
    func testDirectSectionsAppendWithoutRemovingRepetitions() {
        var transcript = RecordingTranscript()
        transcript.appendSettled(.init(id: 0, startSample: 0, endSample: 16_000,
                                       text: "Again", translation: "Uudelleen"))
        transcript.appendSettled(.init(id: 16_000, startSample: 16_000, endSample: 32_000,
                                       text: "Again", translation: "Uudelleen"))
        transcript.appendSettled(.init(id: 8_000, startSample: 8_000, endSample: 9_000,
                                       text: "stale"))
        XCTAssertEqual(transcript.utterances.count, 2)
        XCTAssertEqual(transcript.text, "Again Again")
        XCTAssertEqual(transcript.translatedText, "Uudelleen Uudelleen")
        XCTAssertTrue(transcript.hasSnapshots)
    }
    private func segment(_ id: UInt64, _ text: String, start: Int? = nil, end: Int? = nil) -> CaptionSegment {
        .init(id: id, startSample: start ?? Int(id - 1) * 80_000, endSample: end ?? Int(id) * 80_000, text: text, state: .confirmed)
    }
    func testCaptionWindowCannotEraseTheSavedMeetingOrItsBeginningAtStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var transcript = RecordingTranscript()
        for id in 1...240 {
            let window = max(1, id - 23)...id
            transcript.apply(.init(revision: UInt64(id), confirmed: window.map { segment(UInt64($0), "Phrase \($0).") }, provisional: ""))
        }
        transcript.finish(fallback: "Phrase 240.", endSample: 19_200_000)
        var note = VoiceNote(text: transcript.text, sourceLanguage: "fi", duration: 1200, model: "test")
        note.utterances = transcript.utterances; note.transcriptionComplete = true
        try await NoteRepository(directory: root).save(note)
        let reopened = try await NoteRepository(directory: root).all()
        XCTAssertEqual(reopened.first?.utterances?.count, 240)
        XCTAssertEqual(reopened.first?.text, (1...240).map { "Phrase \($0)." }.joined(separator: " "))
    }
    func testContextCorrectionReplacesOnlyCoveredUtterances() {
        var log = RecordingTranscript()
        log.apply(.init(revision: 1, confirmed: [segment(1, "first"), segment(2, "draft")], provisional: ""))
        log.apply(.init(revision: 2, confirmed: [segment(2, "first corrected", start: 0), segment(3, "third")], provisional: "", settledThroughSample: 160_000))
        log.apply(.init(revision: 3, confirmed: [segment(1, "late first"), segment(3, "third")], provisional: "next"))
        XCTAssertEqual(log.utterances.map(\.text), ["first corrected", "third"])
        XCTAssertTrue(log.utterances[0].settled)
        XCTAssertEqual(log.text, "first corrected third next")
    }
    func testStableBoundaryCanAdvanceWithoutAnotherWordRevision() {
        var log = RecordingTranscript()
        let phrase = segment(1, "finished phrase")
        log.apply(.init(revision: 1, confirmed: [phrase], provisional: "", settledThroughSample: 0))
        XCTAssertFalse(log.utterances[0].settled)
        XCTAssertTrue(log.apply(.init(revision: 1, confirmed: [phrase], provisional: "", settledThroughSample: 80_000)))
        XCTAssertTrue(log.utterances[0].settled)
    }
    func testAudioIsPlayableBeforeStopAndRepairRecoversAnUncheckpointedTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.wav")
        let writer = try PCMRecordingWriter(url: url)
        try writer.append([Float](repeating: 0.25, count: 16_000))
        var data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 32_044)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(Array(data[40..<44]), [0, 125, 0, 0])
        try writer.finish()
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: Data(repeating: 0, count: 32_000)); try file.close()
        XCTAssertEqual(try PCMRecordingWriter.repair(url), 2)
        data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data[40..<44]), [0, 250, 0, 0])
    }
    func testLateDraftCannotOverwriteCompletedNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = NoteRepository(directory: root)
        var note = VoiceNote(text: "complete meeting", sourceLanguage: "fi", duration: 1200, model: "test")
        note.transcriptionComplete = true; note.captureRevision = 9
        try await repo.save(note)
        note.text = "last two minutes"; note.transcriptionComplete = false
        try await repo.saveProgress(note)
        let saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, "complete meeting")
    }
    func testOlderCaptureRevisionCannotOverwriteNewerDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = NoteRepository(directory: root)
        var note = VoiceNote(text: "draft at nine", sourceLanguage: "fi", duration: 600, model: "test")
        note.captureRevision = 9
        try await repo.save(note)
        note.text = "stale draft"; note.captureRevision = 8
        try await repo.saveProgress(note)
        var saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, "draft at nine")
        note.text = "draft at ten"; note.captureRevision = 10
        try await repo.saveProgress(note)
        saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, "draft at ten", "a newer revision must still be saved")
    }
    func testNotesWithoutAudioOrVersionsRoundTrip() throws {
        let note = VoiceNote(text: "Text only", sourceLanguage: "fi", duration: 10, model: "test")
        let decoded = try JSONDecoder().decode(VoiceNote.self, from: JSONEncoder().encode(note))
        XCTAssertNil(decoded.audio); XCTAssertNil(decoded.transcriptVersions)
    }
    func testFailedRetranscriptionLeavesPreviousResultAndSuccessKeepsItsVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = NoteRepository(directory: root)
        var original = VoiceNote(text: "the original meeting", translation: "исходный перевод", sourceLanguage: "fi", targetLanguage: "ru", duration: 1200, model: "test")
        original.audio = RecordedAudio(recordingID: original.id); original.transcriptionComplete = true
        try await repo.save(original)
        let version = TranscriptVersion(note: original)
        var retry = original; retry.text = "a partial retry"; retry.translation = nil; retry.transcriptionComplete = false
        try await repo.saveTranscription(retry, previousVersion: version)
        var saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, original.text)
        retry.text = "the complete new meeting"; retry.transcriptionComplete = true
        try await repo.saveTranscription(retry, previousVersion: version)
        try await repo.saveTranscription(retry, previousVersion: version)
        saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, retry.text)
        XCTAssertEqual(saved.first?.audio, original.audio)
        XCTAssertEqual(saved.first?.transcriptVersions?.count, 1)
        XCTAssertEqual(saved.first?.transcriptVersions?.first?.text, original.text)
        XCTAssertEqual(saved.first?.transcriptVersions?.first?.translation, original.translation)
    }
    func testSeparateWritersCannotLoseOtherNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await NoteRepository(directory: root).save(VoiceNote(text: "note \(index)", sourceLanguage: "fi", duration: 1, model: "test"))
                }
            }
            try await group.waitForAll()
        }
        let recovered = try await NoteRepository(directory: root).all()
        XCTAssertEqual(recovered.count, 20)
        XCTAssertEqual(Set(recovered.map(\.text)), Set((0..<20).map { "note \($0)" }))
    }
    func testDeletedNoteCannotReturnFromLateCaptureCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = NoteRepository(directory: root)
        let note = VoiceNote(text: "draft", sourceLanguage: "fi", duration: 1, model: "test")
        try await repo.save(note); try await repo.delete(note.id); try await repo.saveProgress(note)
        let saved = try await repo.all()
        XCTAssertTrue(saved.isEmpty)
    }
    func testInterruptedCaptureCannotBeOverwrittenByALateDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = NoteRepository(directory: root)
        var note = VoiceNote(text: "all captured speech", sourceLanguage: "fi", duration: 1200, model: "test")
        note.transcriptionComplete = false; note.captureClosed = true
        try await repo.save(note)
        note.text = "older window"; note.captureClosed = false
        try await repo.saveProgress(note)
        let saved = try await repo.all()
        XCTAssertEqual(saved.first?.text, "all captured speech")
    }
    func testTwentyMinuteAudioRetainsFirstAndLastSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = RecordedAudio()
        let url = try reference.url(in: root)
        let writer = try PCMRecordingWriter(url: url)
        let second = [Float](repeating: 0.25, count: 16_000)
        for _ in 0..<1199 { try writer.append(second) }
        try writer.append([Float](repeating: -0.25, count: 16_000)); try writer.finish()
        XCTAssertEqual(reference.capturedDuration(in: root), 1200)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        try file.seek(toOffset: 44); let first = try file.read(upToCount: 2)
        try file.seek(toOffset: 44 + 1200 * 32_000 - 2); let last = try file.read(upToCount: 2)
        XCTAssertEqual(first, Data([0, 32])); XCTAssertEqual(last, Data([0, 224]))
        XCTAssertThrowsError(try PCMRecordingWriter(url: url))
    }
}
