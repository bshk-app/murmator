@testable import MurmurTranslation
import MurmurCore
import XCTest

private final class OnceExpectation: @unchecked Sendable {
    let value: XCTestExpectation
    private let lock = NSLock()
    private var fulfilled = false
    init(_ value: XCTestExpectation) { self.value = value }
    func fulfill() {
        lock.lock()
        let shouldFulfill = !fulfilled
        fulfilled = true
        lock.unlock()
        if shouldFulfill { value.fulfill() }
    }
}

private actor TranslatedSegments {
    private(set) var values: [UtteranceTranslation] = []
    func append(_ value: UtteranceTranslation) { values.append(value) }
}

private actor RecoveringTranslation {
    private var available = false
    private var result = "hello"
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false
    private var onWait: (@Sendable () -> Void)?

    func recover(with result: String = "hello") { available = true; self.result = result }
    func hold(onWait: @escaping @Sendable () -> Void) { held = true; self.onWait = onWait }
    func release() { held = false; gate?.resume(); gate = nil }

    func translate(_ text: String, from: String, to: String) async throws -> String {
        calls += 1
        if held {
            await withCheckedContinuation {
                gate = $0
                onWait?()
                onWait = nil
            }
        }
        guard available else { throw URLError(.fileDoesNotExist) }
        return result
    }
}

final class TranslationSessionTests: XCTestCase {
    private func session(_ engine: RecoveringTranslation) -> TranslationSession {
        TranslationSession(modelsRoot: FileManager.default.temporaryDirectory,
                           fastTranslation: { text, _, _ in text.isEmpty ? "" : "preview" },
                           qualityTranslation: { try await engine.translate($0, from: $1, to: $2) })
    }

    private func snapshot(_ revision: UInt64 = 1) -> CaptionSnapshot {
        .init(revision: revision, confirmed: [
            .init(id: 1, startSample: 0, endSample: 16_000, text: "привет", state: .confirmed)
        ], provisional: "")
    }

    func testFailedFinalPhraseRetriesAfterTheModelBecomesAvailable() async {
        let engine = RecoveringTranslation()
        let session = session(engine)
        let failed = OnceExpectation(expectation(description: "missing model reported for the phrase"))
        await session.update(snapshot(), from: "ru", to: "en", onUpdate: { _ in }, onFailure: { _ in },
                             onSegments: { if $0.contains(where: { $0.id == 1 && $0.failed }) { failed.fulfill() } })
        await fulfillment(of: [failed.value], timeout: 2)
        await engine.recover()

        let recovered = OnceExpectation(expectation(description: "same phrase receives a final translation"))
        // Even the same revision may be re-emitted once preparation finishes.
        await session.update(snapshot(), from: "ru", to: "en", onUpdate: { _ in }, onFailure: { _ in },
                             onSegments: {
            if $0.contains(where: { $0.id == 1 && $0.text == "hello" && $0.isFinal && !$0.failed }) {
                recovered.fulfill()
            }
        })
        await fulfillment(of: [recovered.value], timeout: 2)
        let calls = await engine.calls
        XCTAssertEqual(calls, 2, "recovery must run the engine again for unchanged text")
        await session.cancel()
    }

    func testSuccessfulFinalTranslationsRemainCachedIncludingEmptyResults() async throws {
        for result in ["hello", ""] {
            let engine = RecoveringTranslation()
            await engine.recover(with: result)
            let session = session(engine)
            let completed = OnceExpectation(expectation(description: "successful final result: \(result)"))
            await session.update(snapshot(), from: "ru", to: "en", onUpdate: { _ in }, onFailure: { _ in },
                                 onSegments: {
                if $0.contains(where: { $0.id == 1 && $0.text == result && $0.isFinal && !$0.failed }) {
                    completed.fulfill()
                }
            })
            await fulfillment(of: [completed.value], timeout: 2)

            for revision in 2...6 {
                await session.update(snapshot(UInt64(revision)), from: "ru", to: "en",
                                     onUpdate: { _ in }, onFailure: { _ in })
            }
            let output = TranslatedSegments()
            try await session.finishUtterances([
                .init(id: 1, startSample: 0, endSample: 16_000, text: "привет")
            ], from: "ru", to: "en", onSegment: { await output.append($0) })
            let emitted = await output.values
            XCTAssertEqual(emitted.count, 1)
            XCTAssertEqual(emitted.first?.text, result)
            XCTAssertEqual(emitted.first?.failed, false)
            let calls = await engine.calls
            XCTAssertEqual(calls, 1, "successful results must survive later snapshots and finalization")
        }
    }

    func testSnapshotsDoNotDuplicateAnInFlightRetry() async {
        let engine = RecoveringTranslation()
        let session = session(engine)
        let failed = OnceExpectation(expectation(description: "initial failure"))
        await session.update(snapshot(), from: "ru", to: "en", onUpdate: { _ in }, onFailure: { _ in },
                             onSegments: { if $0.contains(where: { $0.failed }) { failed.fulfill() } })
        await fulfillment(of: [failed.value], timeout: 2)
        await engine.recover()
        let waiting = OnceExpectation(expectation(description: "retry is waiting in the engine"))
        await engine.hold { waiting.fulfill() }

        let completed = OnceExpectation(expectation(description: "retry completed"))
        for revision in 2...6 {
            await session.update(snapshot(UInt64(revision)), from: "ru", to: "en", onUpdate: { _ in }, onFailure: { _ in },
                                 onSegments: {
                if $0.contains(where: { $0.text == "hello" && $0.isFinal && !$0.failed }) { completed.fulfill() }
            })
        }
        await fulfillment(of: [waiting.value], timeout: 2)
        let calls = await engine.calls
        XCTAssertEqual(calls, 2)
        await engine.release()
        await fulfillment(of: [completed.value], timeout: 2)
        await session.cancel()
    }
}
