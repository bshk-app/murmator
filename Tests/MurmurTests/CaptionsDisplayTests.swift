import AppKit
import MurmurCaptions
import XCTest
@testable import Murmur

/// The saved display must win over the cursor, and a saved display that is
/// not connected must still put the captions on a screen that exists — the
/// talk cannot stop because the projector was plugged into another port.
@MainActor
final class CaptionsDisplayTests: XCTestCase {
    func testEveryConnectedScreenHasAStableUUID() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let uuid = try XCTUnwrap(CaptionsDisplay.uuid(of: screen))
        XCTAssertEqual(CaptionsDisplay.uuid(of: screen), uuid)
        XCTAssertEqual(CaptionsDisplay.screen(for: uuid), screen)
    }

    func testEachPinnedScreenResolvesToItself() {
        for screen in NSScreen.screens {
            guard let uuid = CaptionsDisplay.uuid(of: screen) else { return XCTFail("no UUID for \(screen)") }
            XCTAssertEqual(CaptionsDisplay.resolve(uuid), screen)
        }
    }

    func testADisconnectedDisplayFallsBackToAConnectedOne() throws {
        let missing = UUID().uuidString
        XCTAssertNil(CaptionsDisplay.screen(for: missing))
        let fallback = try XCTUnwrap(CaptionsDisplay.resolve(missing))
        XCTAssertTrue(NSScreen.screens.contains(fallback))
        XCTAssertEqual(fallback, NSScreen.underCursor)
    }

    /// The band is sized from the screen it lands on and sits inside its
    /// visible area, clear of the bottom edge.
    func testTheBandIsPlacedAndSizedOnThePinnedScreen() throws {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        for screen in NSScreen.screens {
            let uuid = try XCTUnwrap(CaptionsDisplay.uuid(of: screen))
            overlay.begin(target: "", display: uuid)
            let frame = try XCTUnwrap(overlay.panelFrame)
            let expected = CaptionsLayout(screen: screen.frame.size, translating: false)
            XCTAssertEqual(overlay.model.layout, expected)
            XCTAssertEqual(frame.size, expected.bandSize)
            XCTAssertTrue(screen.visibleFrame.contains(frame), "\(frame) not inside \(screen.visibleFrame)")
            XCTAssertEqual(frame.minY, screen.visibleFrame.minY + expected.bottomInset)
        }
    }

    func testTurningTranslationOnMidTalkKeepsTheBandCompact() throws {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        let plain = try XCTUnwrap(overlay.panelFrame)
        overlay.setTranslationTarget("EN")
        let translating = try XCTUnwrap(overlay.panelFrame)
        XCTAssertEqual(overlay.model.layout.translationLines, 3)
        XCTAssertGreaterThan(translating.height, plain.height)
        let screen = try XCTUnwrap(CaptionsDisplay.resolve(CaptionsDisplay.followCursor))
        XCTAssertLessThan(translating.height, screen.frame.height * 0.30)
        XCTAssertEqual(translating.minY, plain.minY, "changing tracks must preserve the bottom edge")
    }

    /// Stop and start again inside the fade: the old fade's completion must
    /// not hide the new talk's band.
    func testARestartDuringTheFadeOutKeepsTheNewBandOnScreen() {
        let overlay = CaptionsOverlay(defaults: UserDefaults(suiteName: "CaptionsTests.\(UUID().uuidString)")!)
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        overlay.dismiss()
        overlay.begin(target: "", display: CaptionsDisplay.followCursor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(overlay.isVisible)
    }
}

// Layout, scrolling and text-diff tests live with the code in Engine/Captions.
@MainActor
final class CaptionsCustomizationTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "CaptionsCustomizationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAppearanceAndPerScreenFramesSurviveReload() {
        let preferences = CaptionsPreferences(defaults: defaults)
        preferences.appearance.fontFamily = "Menlo"
        preferences.appearance.automaticFontSize = false
        preferences.appearance.fontSize = 34
        preferences.appearance.backgroundOpacity = 0.45
        preferences.appearance.textColor = CaptionsColor(.cyan)
        preferences.appearance.translationColor = CaptionsColor(.green)
        preferences.appearance.backgroundColor = CaptionsColor(.blue)
        let visible = NSRect(x: -1920, y: 24, width: 1920, height: 1056)
        let first = NSRect(x: -1500, y: 120, width: 900, height: 350)
        let second = NSRect(x: -1100, y: 240, width: 700, height: 250)
        preferences.save(frame: first, on: "first", visible: visible)
        preferences.save(frame: second, on: "second", visible: visible)
        let loaded = CaptionsPreferences(defaults: defaults)
        XCTAssertEqual(loaded.appearance, preferences.appearance)
        XCTAssertEqual(loaded.placement(for: "first")?.frame(in: visible), first)
        XCTAssertEqual(loaded.placement(for: "second")?.frame(in: visible), second)
        loaded.resetPlacement(for: "first")
        XCTAssertNil(CaptionsPreferences(defaults: defaults).placement(for: "first"))
        XCTAssertNotNil(CaptionsPreferences(defaults: defaults).placement(for: "second"))
    }

    func testPreviewUnlocksWithoutRecordingAndDoneDismissesIt() {
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.setEditing(true, display: CaptionsDisplay.followCursor, translating: true)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertTrue(overlay.acceptsInteraction)
        XCTAssertEqual(overlay.model.layout.translationLines, 3)
        overlay.setEditing(false)
        XCTAssertFalse(overlay.acceptsInteraction)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertFalse(overlay.isVisible)
    }

    func testLockingLiveCaptionsKeepsTextAndWindowVisible() {
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.begin(target: "EN", display: CaptionsDisplay.followCursor)
        overlay.update(confirmed: "Продолжаем выступление", partial: "новая фраза")
        overlay.setEditing(true)
        overlay.setEditing(false)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertFalse(overlay.acceptsInteraction)
        XCTAssertEqual(overlay.model.confirmed, "Продолжаем выступление")
        XCTAssertEqual(overlay.model.partial, "новая фраза")
        overlay.dismiss()
    }

    func testResizeAddsLinesAndRestoresPositionAtNextStart() throws {
        let screen = try XCTUnwrap(CaptionsDisplay.resolve(CaptionsDisplay.followCursor))
        let overlay = CaptionsOverlay(defaults: defaults)
        overlay.begin(target: "EN", display: CaptionsDisplay.followCursor)
        let original = try XCTUnwrap(overlay.panelFrame)
        overlay.setEditing(true)
        let larger = NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 25,
                            width: original.width * 0.8, height: original.height * 1.6)
        overlay.setManualFrame(larger)
        let saved = try XCTUnwrap(overlay.panelFrame)
        XCTAssertGreaterThan(overlay.model.layout.transcriptLines, 3)
        XCTAssertGreaterThan(overlay.model.layout.translationLines, 3)
        XCTAssertEqual(saved.size, overlay.model.layout.bandSize)
        overlay.dismiss()
        let restored = CaptionsOverlay(defaults: defaults)
        restored.begin(target: "EN", display: CaptionsDisplay.followCursor)
        XCTAssertEqual(try XCTUnwrap(restored.panelFrame).minX, saved.minX, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(restored.panelFrame).height, saved.height, accuracy: 0.5)
        restored.preferences.appearance.automaticFontSize = false
        restored.preferences.appearance.fontSize = 38
        XCTAssertEqual(restored.model.layout.fontSize, 38)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(restored.panelFrame).height, restored.model.layout.minimumSize.height)
        restored.resetPlacement(display: CaptionsDisplay.followCursor)
        XCTAssertEqual(restored.model.layout.transcriptLines, 3)
        restored.dismiss()
    }

    func testFrameFittingAndCornerDragKeepThePanelReachable() {
        let visible = NSRect(x: -1600, y: 40, width: 1600, height: 860)
        let fitted = CaptionsPlacement.fitted(NSRect(x: -3000, y: -100, width: 2400, height: 1200),
                                              visible: visible, minimum: CGSize(width: 320, height: 200))
        XCTAssertEqual(fitted, visible)
        let original = NSRect(x: 100, y: 100, width: 800, height: 300)
        let resized = CaptionsInteractionView.dragged(frame: original, dx: 120, dy: -80, resizing: true,
                                                       minimum: CGSize(width: 320, height: 200))
        XCTAssertEqual(resized.maxY, original.maxY)
        XCTAssertEqual(resized.minX, original.minX)
        XCTAssertEqual(resized.size, CGSize(width: 920, height: 380))
        let moved = CaptionsInteractionView.dragged(frame: original, dx: -30, dy: 40, resizing: false, minimum: .zero)
        XCTAssertEqual(moved, original.offsetBy(dx: -30, dy: 40))
    }
}
