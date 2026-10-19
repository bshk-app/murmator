@testable import MurmurTranslation
import MurmurCore
import XCTest

final class TranslatorFailureTests: XCTestCase {
    func testIncompleteModelReturnsReadableEngineError() throws {
        try checkDamagedModel(truncated: false)
    }

    func testTruncatedInstallReturnsReadableEngineError() throws {
        try checkDamagedModel(truncated: true)
    }

    func testPartialWeightsWithValidVocabularyAndShortlistReturnError() throws {
        let modelName = "model.ruen.intgemm.alphas.bin"
        guard let installed = bergamotModels?.appendingPathComponent("moz-ruen"),
              FileManager.default.fileExists(atPath: installed.appendingPathComponent(modelName).path) else {
            throw XCTSkip("translation model not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = LanguagePair(source: "ru", target: "en")
        let directory = root.appendingPathComponent(pair.modelDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try TranslationDownloader.writeConfig(for: pair, into: directory)
        for name in ["vocab.ruen.spm", "lex.50.50.ruen.s2t.bin"] {
            try FileManager.default.copyItem(at: installed.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        let input = try FileHandle(forReadingFrom: installed.appendingPathComponent(modelName))
        defer { try? input.close() }
        let prefix = try XCTUnwrap(input.read(upToCount: 1024))
        try prefix.write(to: directory.appendingPathComponent(modelName))
        XCTAssertThrowsError(try Translator(pair: pair, modelsRoot: root)) { error in
            guard case Translator.Failure.engine(let message) = error else {
                return XCTFail("Expected native loading failure, got \(error)")
            }
            XCTAssertTrue(message.contains("binary file is invalid"), message)
        }
    }

    private func checkDamagedModel(truncated: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = LanguagePair(source: "ru", target: "en")
        let directory = root.appendingPathComponent(pair.modelDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try TranslationDownloader.writeConfig(for: pair, into: directory)
        if truncated {
            for name in ["model.ruen.intgemm.alphas.bin", "vocab.ruen.spm", "lex.50.50.ruen.s2t.bin"] {
                try Data().write(to: directory.appendingPathComponent(name))
            }
        }
        XCTAssertThrowsError(try Translator(pair: pair, modelsRoot: root)) { error in
            guard case Translator.Failure.engine(let message) = error else {
                return XCTFail("Expected native loading failure, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertEqual(error.localizedDescription, "translation engine: \(message)")
        }
    }
}
