import Foundation

/// Pure, UI-agnostic state + rules for the first-run onboarding wizard. The app's
/// `OnboardingModel` owns the real subsystems and consults this for every
/// transition and gate. Foundation-only so it unit-tests without MLX.
public enum OnboardingFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, microphone, models, fast, hybrid, accurate, corrector, translation, caret, done

        /// Steps with a recording example. Trying it is optional.
        public var isExample: Bool {
            switch self {
            case .fast, .hybrid, .accurate, .corrector, .translation, .caret: return true
            case .welcome, .microphone, .models, .done: return false
            }
        }
    }

    /// Rounded on-disk sizes (GB) of the two model repositories.
    public static let fastGB = 0.8
    public static let accurateGB = 2.6
    public static var totalGB: Double { fastGB + accurateGB }

    public struct State: Sendable {
        public var step: Step = .welcome
        public var micGranted = false
        public var accessibilityGranted = false
        public var fastFraction = 0.0       // 0…1
        public var accurateFraction = 0.0   // 0…1
        public var didTry = false           // ≥1 successful example dictation
        public init() {}
    }

    /// Continue is allowed unless the current step has an unmet requirement.
    /// The microphone and the models are required; every example is optional,
    /// and Accessibility is never gated (the practice field works without it).
    public static func canContinue(_ s: State) -> Bool {
        switch s.step {
        case .microphone: return s.micGranted
        case .models:     return s.fastFraction >= 1 && s.accurateFraction >= 1
        default:          return true
        }
    }

    public static func next(_ step: Step) -> Step {
        Step(rawValue: min(step.rawValue + 1, Step.done.rawValue)) ?? .done
    }
    public static func back(_ step: Step) -> Step {
        Step(rawValue: max(step.rawValue - 1, 0)) ?? .welcome
    }
}
