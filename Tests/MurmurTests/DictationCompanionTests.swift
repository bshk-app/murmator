import AppKit
import XCTest
@testable import Murmur

@MainActor final class DictationCompanionTests: XCTestCase {
    func testStatusStaysInsideDisplaysIncludingNegativeCoordinates() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1440, y: -400, width: 1440, height: 900)] {
            for point in [CGPoint(x: screen.minX, y: screen.minY),
                          CGPoint(x: screen.maxX, y: screen.maxY),
                          CGPoint(x: screen.midX, y: screen.midY)] {
                let frame = DictationCompanion.placement(near: CGRect(origin: point, size: .zero), visible: screen)
                XCTAssertTrue(screen.contains(frame))
            }
        }
    }

    func testProgressDoesNotMoveTheCompanionToADifferentCursor() throws {
        let companion = DictationCompanion()
        companion.waitDelay = 0
        companion.locateCaret = { .notFound }
        var point = CGPoint(x: 500, y: 500)
        companion.pointer = { point }
        companion.preparing("Loading", fraction: 0.1, onCancel: {})
        let frame = try XCTUnwrap(companion.frame)
        point = CGPoint(x: 800, y: 800)
        companion.updatePreparation("Warming up", fraction: 0.9)
        XCTAssertEqual(companion.frame, frame)
        XCTAssertEqual(companion.model.message, "Warming up")
        companion.dismiss()
        XCTAssertFalse(companion.isVisible)
    }

    func testCatMotionIsBoundedAndHonorsReduceMotion() {
        for expression in [MascotExpression.happy, .thinking, .listening, .celebrating, .sad] {
            for time in stride(from: 0.0, to: 15, by: 0.1) {
                let motion = MascotMotion(expression: expression, elapsed: time, reduceMotion: false)
                XCTAssertLessThanOrEqual(abs(motion.rotation), 7)
                XCTAssertLessThanOrEqual(abs(motion.lift), 4)
                XCTAssertLessThanOrEqual(abs(motion.scale - 1), 0.026)
                let still = MascotMotion(expression: expression, elapsed: time, reduceMotion: true)
                XCTAssertEqual(still.rotation, 0); XCTAssertEqual(still.lift, 0); XCTAssertEqual(still.scale, 1)
            }
        }
    }

    func testAnOrdinaryAttemptDoesNotShowAnAdviserOrLeaveADelayedPopup() async throws {
        let companion = DictationCompanion()
        companion.waitDelay = 0.05
        companion.preparing("Preparing", onCancel: {})
        XCTAssertFalse(companion.isVisible)
        companion.dismiss()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(companion.isVisible, "a ready recording must never get a stale loading mascot")
    }
}
