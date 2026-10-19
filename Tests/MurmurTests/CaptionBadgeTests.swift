import XCTest
@testable import Murmur
@testable import MurmurKit

/// The caption band's translation track follows the Translate-to picker, which
/// stays live for the whole talk: the target captured at the start is not
/// enough, or the band keeps reserving a track for a language that is no
/// longer arriving - or none at all.
///
/// The fake session keeps these presentation tests independent of inference.
@MainActor
final class CaptionBadgeTests: XCTestCase {
    private var savedTarget: String?

    override func setUpWithError() throws {
        savedTarget = UserDefaults.standard.string(forKey: TranslationSetting.key)
    }

    override func tearDownWithError() throws {
        if let savedTarget {
            UserDefaults.standard.set(savedTarget, forKey: TranslationSetting.key)
        } else {
            UserDefaults.standard.removeObject(forKey: TranslationSetting.key)
        }
    }

    private func target(_ value: String) {
        UserDefaults.standard.set(value, forKey: TranslationSetting.key)
    }

    /// A caption talk already on screen, translating ru -> en, as
    /// `beginRecording` leaves things in captions mode - but with a fake
    /// session in place of the real one.
    private func talking() -> DictationController {
        let controller = DictationController()
        controller.session = FakeDictationSession()
        target("en")
        controller.captionSource = "ru"
        controller.captionTarget = "en"
        controller.captionsOverlay.begin(target: "EN", display: CaptionsDisplay.followCursor)
        return controller
    }

    /// Apply the current target setting and wait for the work it started, so
    /// no translation task survives the test that spawned it.
    private func retarget(_ controller: DictationController) async {
        controller.updateCaptionTarget()
        await controller.captionTranslateTask?.value
    }

    func testTheBadgeFollowsATargetChangedMidTalk() async {
        let controller = talking()
        await retarget(controller)
        XCTAssertEqual(controller.captionsOverlay.model.target, "EN", "baseline: the talk started as ru -> en")

        // The user reopens the menu mid-talk and picks German.
        target("de")
        await retarget(controller)

        XCTAssertEqual(controller.captionsOverlay.model.target, "DE",
                       "the second track is German now")
    }

    /// Switching translation off takes the track away together with its text.
    func testTheBadgeClearsWhenTranslationIsSwitchedOffMidTalk() async {
        let controller = talking()
        await retarget(controller)
        XCTAssertEqual(controller.captionsOverlay.model.target, "EN")
        controller.captionsOverlay.showTranslation("hello")

        target(TranslationSetting.off)
        await retarget(controller)

        XCTAssertEqual(controller.captionsOverlay.model.target, "")
        XCTAssertEqual(controller.captionsOverlay.model.translation, "")
        XCTAssertEqual(controller.captionsOverlay.model.layout.translationLines, 0,
                       "no translation means no reserved track on the band")
    }

    /// The track and the translation are gated on the same predicate, so an
    /// unroutable target must drop the track rather than promise a language
    /// that never arrives.
    func testTheBadgeClearsWhenTheNewTargetIsUnroutable() async {
        let controller = talking()
        await retarget(controller)

        target("xx")
        XCTAssertNil(LanguagePair.route(from: "ru", to: "xx"),
                     "xx is expected to be unsupported; test assumption is stale")
        await retarget(controller)

        XCTAssertEqual(controller.captionsOverlay.model.target, "")
    }
}
