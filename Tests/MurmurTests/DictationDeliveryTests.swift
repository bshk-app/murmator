import XCTest
import Foundation
import Darwin
@testable import Murmur
@testable import MurmurKit

@MainActor final class DictationDeliveryTests: XCTestCase {
    func testPasteCompletionSurvivesUnwritableStandardError() throws {
        let controller = DictationController(session: FakeDictationSession())
        controller.accessibilityTrusted = { true }
        var settle: (@Sendable (Bool) -> Void)?
        controller.pasteTranscript = { _, _, callback in settle = callback; return .pasted }
        controller.deliverFinal("Finished text.", source: "Finished text.", submit: false)
        _ = FileHandle.standardError
        let saved = dup(STDERR_FILENO)
        guard saved >= 0 else { return XCTFail("Cannot preserve stderr") }
        defer { _ = dup2(saved, STDERR_FILENO); close(saved) }
        let unwritable = open("/dev/null", O_RDONLY)
        guard unwritable >= 0 else { return XCTFail("Cannot open fixture descriptor") }
        defer { close(unwritable) }
        XCTAssertGreaterThanOrEqual(dup2(unwritable, STDERR_FILENO), 0)
        // The old Foundation writeData logger raises an uncaught ObjC exception
        // here, matching the production crash. Run this case in its own host.
        settle?(true)
        _ = dup2(saved, STDERR_FILENO)
        XCTAssertFalse(controller.isDelivering)
        XCTAssertEqual(controller.lastOutputText, "Finished text.")
        XCTAssertNil(controller.sessionWarning)
    }

    func testPostingPasteKeepsTheResultPendingUntilItIsRead() {
        let controller = DictationController(session: FakeDictationSession())
        controller.accessibilityTrusted = { true }
        var settle: (@Sendable (Bool) -> Void)?
        controller.pasteTranscript = { text, submit, callback in
            XCTAssertEqual(text, "Corrected result.")
            XCTAssertFalse(submit)
            settle = callback
            return .pasted
        }
        let delivery = controller.deliverFinal("Corrected result.", source: "Corrected result.", submit: false)
        XCTAssertEqual(delivery, .typed)
        XCTAssertTrue(controller.isDelivering, "posting a key is not the end of delivery")
        XCTAssertEqual(controller.lastOutputText, "Corrected result.")
        settle?(true)
        XCTAssertFalse(controller.isDelivering)
        XCTAssertNil(controller.sessionWarning)
    }

    func testUnreadPasteShowsFailureAndKeepsTheCompleteTranslatedOutputForRecovery() {
        let controller = DictationController(session: FakeDictationSession())
        controller.accessibilityTrusted = { true }
        var settle: (@Sendable (Bool) -> Void)?
        controller.pasteTranscript = { _, _, callback in settle = callback; return .pasted }
        controller.deliverFinal("Полный перевод.", source: "Full original.", translation: "Полный перевод.", submit: false)
        settle?(false)
        XCTAssertFalse(controller.isDelivering)
        XCTAssertEqual(controller.lastOutputText, "Полный перевод.")
        XCTAssertNotNil(controller.sessionWarning)
        XCTAssertEqual(controller.companion.model.phase, .error)
    }

    func testImmediatePasteFailureRetainsRecoveryAndDoesNotWaitForCallback() {
        let controller = DictationController(session: FakeDictationSession())
        controller.accessibilityTrusted = { true }
        controller.pasteTranscript = { _, _, _ in .failed }
        let delivery = controller.deliverFinal("Finished text.", source: "Finished text.", submit: false)
        guard case .failed = delivery else { return XCTFail("must report paste failure") }
        XCTAssertFalse(controller.isDelivering)
        XCTAssertEqual(controller.lastOutputText, "Finished text.")
    }

    func testEmptyTakeDoesNotEraseLastRecoverableResult() {
        let controller = DictationController(session: FakeDictationSession())
        controller.accessibilityTrusted = { true }
        controller.pasteTranscript = { _, _, _ in .failed }
        controller.deliverFinal("Previous result.", source: "Previous result.", submit: false)
        controller.deliverFinal("", source: "", submit: false)
        XCTAssertEqual(controller.lastOutputText, "Previous result.")
    }
}
