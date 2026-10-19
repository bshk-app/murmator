import XCTest
@testable import MurmurCore

final class LongConversationTests: XCTestCase {
    func testTwentyMinuteMeetingSurvivesStopAndRepositoryReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var phrase = 0
        let engine = CaptionEngine(live: .init(begin: {}, step: { _ in }, text: { "draft" }, finish: {}),
            isSpeech: { $0.contains { $0 != 0 } },
            batch: { _, _ in phrase += 1; return "Meeting phrase \(phrase)." },
            endpointSilence: 0.064, preRoll: 0)
        let speech = [Float](repeating: 1, count: 1536)
        let silence = [Float](repeating: 0, count: 1536)
        var display = CorrectionDisplay()
        for _ in 0..<240 {
            for _ in 0..<51 { engine.step(speech) }
            engine.step(silence)
            display.update(engine.snapshot())
        }
        engine.finish()
        let final = engine.snapshot().confirmed.map(\.text).joined(separator: " ")
        display.finish(final)
        let note = VoiceNote(text: display.text, sourceLanguage: "fi", duration: 240 * 52 * 0.096, model: "test recognizer")
        try await NoteRepository(directory: directory).save(note)
        let saved = try await NoteRepository(directory: directory).all()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.text, (1...240).map { "Meeting phrase \($0)." }.joined(separator: " "))
    }
    func testReadingBlocksKeepEveryCharacterAndHaveBoundedLayouts() {
        let text = "Начало собрания.\n\n" + String(repeating: "Hyvää iltaa! Puhutaan koulusta, ystävistä ja läksyistä. 👨‍👩‍👧‍👦\n", count: 900) + "\nКонец собрания."
        let blocks = TranscriptContent.blocks(text)
        XCTAssertEqual(blocks.map(\.text).joined(), text)
        XCTAssertTrue(blocks.allSatisfy { $0.text.count <= 700 })
        XCTAssertGreaterThan(blocks.count, 50)
        XCTAssertEqual(TranscriptContent.blocks(""), [])
    }

    func testFirstPhraseSurvivesLongConversationAndFinalSave() {
        var phrase = 0
        let engine = CaptionEngine(
            live: .init(begin: {}, step: { _ in }, text: { "draft" }, finish: {}),
            isSpeech: { $0.contains { $0 != 0 } },
            batch: { _, _ in phrase += 1; return "Meeting phrase \(phrase)." },
            endpointSilence: 0.064, preRoll: 0
        )
        for _ in 0..<100 {
            engine.step(Array(repeating: 1, count: 1536))
            engine.step(Array(repeating: 0, count: 1536))
        }
        engine.finish()
        let snapshot = engine.snapshot()
        XCTAssertEqual(phrase, 100)
        XCTAssertEqual(snapshot.confirmed.count, 100, "The screen and saved note must retain the whole meeting")
        XCTAssertEqual(snapshot.confirmed.first?.text, "Meeting phrase 1.")
        XCTAssertEqual(snapshot.confirmed.last?.text, "Meeting phrase 100.")
        var display = CorrectionDisplay()
        display.update(snapshot)
        XCTAssertTrue(display.text.hasPrefix("Meeting phrase 1."), "Scrolling cannot restore text that was discarded")
        XCTAssertLessThan(engine.bufferedSamples, 4096, "Keeping text must not retain the meeting's PCM audio")
    }
}
