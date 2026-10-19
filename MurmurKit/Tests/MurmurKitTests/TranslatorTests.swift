import XCTest

@testable import MurmurKit

/// Model-backed tests are skipped when the models are absent, so a checkout
/// without the ~1 GB download still passes. The routing tests never need them.
final class TranslatorTests: XCTestCase {
    private func translator(_ pair: LanguagePair) throws -> Translator? {
        guard let modelsRoot = bergamotModels else { return nil }
        do {
            return try Translator(pair: pair, modelsRoot: modelsRoot)
        } catch Translator.Failure.modelUnavailable {
            return nil
        }
    }

    func test_translates_a_committed_utterance() throws {
        guard let engine = try translator(LanguagePair(source: "ru", target: "en"))
        else { throw XCTSkip("ru-en model not installed") }

        let source = "Можем ли мы перенести встречу на четверг?"
        let started = Date()
        let out = try engine.translate(source)
        let elapsed = Date().timeIntervalSince(started) * 1000
        // Printed, not asserted: a latency bound here would fail on a loaded
        // machine and tell nobody anything. The measured budget lives in the
        // omni-bench Results, not in a unit test.
        print(String(format: "  [translate] %.1f ms  %@ -> %@", elapsed, source, out))
        XCTAssertFalse(out.isEmpty)
        // Not an exact-match assertion: greedy decoding is deterministic per
        // build but the wording is the model's, not the test's. What must hold
        // is that the output is English and carries the content words.
        XCTAssertTrue(out.lowercased().contains("thursday"), out)
        XCTAssertTrue(out.lowercased().contains("meeting"), out)
    }

    func test_empty_input_is_not_an_error() throws {
        guard let engine = try translator(LanguagePair(source: "ru", target: "en"))
        else { throw XCTSkip("ru-en model not installed") }
        XCTAssertEqual(try engine.translate("   "), "")
    }

    func test_missing_model_reports_the_pair_and_the_path() {
        let pair = LanguagePair(source: "xx", target: "en")
        XCTAssertThrowsError(
            try Translator(pair: pair, modelsRoot: URL(fileURLWithPath: "/nonexistent"))
        ) { error in
            guard case let Translator.Failure.modelUnavailable(reported, path) = error else {
                return XCTFail("expected modelUnavailable, got \(error)")
            }
            XCTAssertEqual(reported, pair)
            XCTAssertEqual(path, "/nonexistent/\(pair.modelDirectoryName)")
        }
    }

    func test_english_pairs_route_directly() {
        XCTAssertEqual(
            LanguagePair.route(from: "ru", to: "en"),
            .direct(LanguagePair(source: "ru", target: "en")))
        XCTAssertEqual(
            LanguagePair.route(from: "en", to: "fi"),
            .direct(LanguagePair(source: "en", target: "fi")))
    }

    func test_non_english_pairs_pivot_through_english() {
        XCTAssertEqual(
            LanguagePair.route(from: "fi", to: "de"),
            .pivot(
                LanguagePair(source: "fi", target: "en"),
                LanguagePair(source: "en", target: "de")))
    }

    func test_unsupported_and_identity_pairs_have_no_route() {
        XCTAssertNil(LanguagePair.route(from: "ru", to: "ru"))
        // Maltese: Mozilla publishes mt-en but no en-mt, so the language is not
        // claimed at all rather than half-claimed.
        XCTAssertNil(LanguagePair.route(from: "en", to: "mt"))
        // Alpha-model languages are excluded on purpose.
        XCTAssertNil(LanguagePair.route(from: "sv", to: "en"))
    }
}
