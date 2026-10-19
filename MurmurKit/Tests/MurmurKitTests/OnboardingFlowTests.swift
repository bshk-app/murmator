import XCTest
@testable import MurmurKit

final class OnboardingFlowTests: XCTestCase {
    func test_steps_follow_the_tour_order() {
        XCTAssertEqual(OnboardingFlow.Step.allCases,
                       [.welcome, .microphone, .models, .fast, .hybrid, .accurate,
                        .corrector, .translation, .caret, .done])
    }

    func test_microphone_gate_requires_mic_access() {
        var s = OnboardingFlow.State()
        s.step = .microphone
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.micGranted = true
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_models_gate_requires_both_models() {
        var s = OnboardingFlow.State()
        s.step = .models
        s.fastFraction = 1; s.accurateFraction = 0.5
        XCTAssertFalse(OnboardingFlow.canContinue(s))
        s.accurateFraction = 1
        XCTAssertTrue(OnboardingFlow.canContinue(s))
    }

    func test_examples_are_optional() {
        for step in [OnboardingFlow.Step.welcome, .fast, .hybrid, .accurate, .corrector, .translation, .caret, .done] {
            var s = OnboardingFlow.State(); s.step = step
            XCTAssertTrue(OnboardingFlow.canContinue(s), "\(step)")
        }
    }

    func test_only_example_steps_record() {
        XCTAssertEqual(OnboardingFlow.Step.allCases.filter(\.isExample),
                       [.fast, .hybrid, .accurate, .corrector, .translation, .caret])
    }

    func test_next_and_back_clamp() {
        XCTAssertEqual(OnboardingFlow.next(.welcome), .microphone)
        XCTAssertEqual(OnboardingFlow.next(.caret), .done)
        XCTAssertEqual(OnboardingFlow.next(.done), .done)
        XCTAssertEqual(OnboardingFlow.back(.microphone), .welcome)
        XCTAssertEqual(OnboardingFlow.back(.welcome), .welcome)
    }
}
