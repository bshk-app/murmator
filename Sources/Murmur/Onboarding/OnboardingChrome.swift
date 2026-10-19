import MurmurKit
import SwiftUI

/// Onboarding-window surfaces beyond the shared `Mur` tokens. The HUD/menu only
/// need accent + glass; the wizard's full canvas (surface/card/footer/stage/ok,
/// per-appearance muted/line tints) comes straight from the design handoff's
/// `applyTheme()`. Accent + error stay `Mur.*` (single source of truth).
struct OnTheme {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ o: Double = 1) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255, opacity: o)
    }

    var ink: Color { dark ? Self.rgb(245, 241, 236) : Self.rgb(42, 37, 32) }
    var surface: Color { dark ? Self.rgb(27, 21, 17) : Self.rgb(255, 253, 249) }
    var card: Color { dark ? Self.rgb(39, 30, 22) : .white }
    var footer: Color { dark ? Self.rgb(22, 17, 12) : Self.rgb(253, 249, 242) }
    var ok: Color { dark ? Self.rgb(116, 196, 126) : Self.rgb(63, 154, 74) }
    var overlay: Color { dark ? Self.rgb(22, 17, 12, 0.97) : Self.rgb(255, 253, 249, 0.97) }

    /// `muted` text tint at a given alpha (mock `--muted-rgb`).
    func muted(_ o: Double) -> Color {
        dark ? Self.rgb(236, 228, 219, o) : Self.rgb(74, 62, 52, o)
    }
    /// `line` hairline/fill tint at a given alpha (mock `--line-rgb`).
    func line(_ o: Double) -> Color {
        dark ? Self.rgb(250, 244, 236, o) : Self.rgb(60, 40, 20, o)
    }

    /// Warm stage backdrop behind the cat/stepper rail.
    var stage: LinearGradient {
        LinearGradient(
            colors: dark
                ? [Self.rgb(36, 27, 19), Self.rgb(29, 21, 15), Self.rgb(24, 17, 9)]
                : [Self.rgb(253, 244, 233), Self.rgb(247, 231, 210), Self.rgb(239, 220, 195)],
            startPoint: .top, endPoint: .bottom)
    }
}

/// Shared mascot artwork.
func onboardingCat(_ size: CGFloat, mood: MascotMood = .idle) -> some View {
    MurmatorMascot(mood: mood, size: size)
}

extension OnboardingFlow.Step {
    /// Stepper and title-bar name.
    var title: LocalizedStringKey {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .models: return "Speech models"
        case .fast: return "Fast"
        case .hybrid: return "Hybrid"
        case .accurate: return "Accurate"
        case .corrector: return "Corrector"
        case .translation: return "Translation"
        case .caret: return "At the caret"
        case .done: return "Done"
        }
    }
}

extension OnboardingModel {
    /// Something needs the user: the cat turns into the advisor only then.
    var needsAdvice: Bool {
        switch step {
        case .microphone: return micDenied || disconnectedMicrophone != nil || micTest.failed
        case .models: return downloadError != nil
        default: return tryError != nil || caretNeedsFocus
        }
    }
}

/// Filled upward triangle — the speech-bubble tail (apex points at the cat).
private struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// Just the two slanted edges of the tail (no base) — so its hairline meets the
/// bubble's border instead of drawing a line across the bubble's top.
private struct BubbleTailEdges: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
    }
}

// MARK: - Left rail: cat + narrator bubble + stepper

struct OnboardingRail: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    /// What the guide card says: one line per step, replaced by advice when
    /// something needs the user. Shown in full at once, resolved from the String Catalog.
    private var narration: String {
        if model.needsAdvice {
            switch model.step {
            case .microphone:
                if model.micDenied { return "I can’t hear anything yet — microphone access is off in System Settings." }
                if model.micTest.failed { return "That input didn’t open. Pick another one and test again." }
                return "Your microphone went away. Recordings use the system default until you pick another."
            case .models: return "Loading didn’t work. Your downloads are kept — try again."
            case .caret where model.caretNeedsFocus: return "Click in the practice field first, so I know where the text goes."
            default: return "That didn’t work. Nothing is lost — read the message below and try again."
            }
        }
        switch model.step {
        case .welcome: return "Hi, I’m Murmator. I’ll show you how dictation works, one step at a time."
        case .microphone: return "First, which microphone should I listen to? Say a few words to test it."
        case .models: return "I need my speech models before I can listen. They stay on this Mac."
        case .fast: return "Fast writes as you talk. It’s quick, and it can mishear — always glance at the text."
        case .hybrid: return "Watch the draft get refined as you speak. Letting go finishes the last phrase."
        case .accurate: return "In Accurate I stay quiet while you talk, then write it all at once."
        case .corrector: return "The corrector tidies spelling and punctuation after you stop. Compare both sides."
        case .translation: return "Pick a language pair and speak. You get both texts side by side."
        case .caret: return "This time the text goes where your insertion point is — just like in any other app."
        case .done: return "That’s the tour. Pick your everyday mode, and reopen this tour any time from the menu."
        }
    }

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            // A fixed slot: the cat never moves when the text around it changes.
            onboardingCat(84, mood: model.needsAdvice ? .error : .idle)
                .frame(width: 96, height: 96)
                .clipped()
                .padding(.bottom, 12)
                .accessibilityHidden(true)   // decorative; the guide text carries the info
            narratorBubble
            Spacer(minLength: 0)
            Text("Tour")
                .tracking(1.4).murFont(10.5, weight: .bold)
                .foregroundStyle(t.muted(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 9)
            stepper
        }
        .padding(.init(top: 22, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 272)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(t.stage)
        .overlay(alignment: .trailing) {
            Rectangle().fill(t.line(0.08)).frame(width: 1)
        }
    }

    private var narratorBubble: some View {
        Text(LocalizedStringKey(narration))
            .murFont(13).lineSpacing(3)
            .foregroundStyle(t.muted(0.96))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
            // Fixed height: the stepper below never moves with the text.
            .frame(height: 112, alignment: .topLeading)
            .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
            // Speech-bubble tail pointing up at the cat → reads as the cat talking.
            .overlay(alignment: .top) {
                ZStack {
                    BubbleTail().fill(t.card)
                    BubbleTailEdges().stroke(t.line(0.1), lineWidth: 1)
                }
                .frame(width: 16, height: 8)
                .offset(y: -6.5)
            }
            .accessibilityHint("Tour guide")
    }

    /// Passed steps can be revisited with a click.
    private var stepper: some View {
        let steps = OnboardingFlow.Step.allCases
        let current = model.step.rawValue
        return VStack(spacing: 2) {
            ForEach(steps, id: \.self) { step in
                let i = step.rawValue
                let done = i < current, active = i == current
                Button { model.jump(to: step) } label: {
                    HStack(spacing: 10) {
                        stepDot(index: i, done: done, active: active)
                        Text(step.title)
                            .murFont(12.5, weight: active ? .semibold : .medium)
                            .foregroundStyle(active ? t.ink : (done ? t.muted(0.72) : t.muted(0.45)))
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!done || model.tryListening || model.tryWorking)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tour steps")
        .accessibilityValue("Step \(current + 1) of \(steps.count)")
    }

    @ViewBuilder
    private func stepDot(index: Int, done: Bool, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(done ? Mur.accent : t.card.opacity(active ? 1 : 0))
                .overlay(Circle().strokeBorder(
                    done ? Mur.accent : (active ? Mur.accent : t.line(0.18)),
                    lineWidth: active ? 2 : (done ? 1 : 1.5)))
            if done {
                Text(verbatim: "✓").font(.system(size: 10, weight: .bold)).foregroundStyle(OnTheme.rgb(26, 18, 12))
            } else {
                Text(verbatim: "\(index + 1)").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(active ? Mur.accent : t.muted(0.42))
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Title bar (traffic lights + centered title)

struct OnboardingTitleBar: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var titleLabel: LocalizedStringKey {
        model.finished ? OnboardingFlow.Step.done.title : model.step.title
    }

    var body: some View {
        // Centered brand + step. The window's real macOS traffic lights sit at the
        // top-left (the window uses a transparent title bar so this row IS the title
        // bar) — so we draw no fake lights, just leave them their space.
        HStack(spacing: 0) {
            Text(verbatim: "Murm").foregroundStyle(t.ink)             // brand — not localized
            Text(verbatim: "ator").foregroundStyle(Mur.accent)
            Text(verbatim: " · ").foregroundStyle(t.muted(0.5))
            Text(titleLabel).foregroundStyle(t.muted(0.62))          // step label — localized
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 15)
        .frame(height: 40)
        .background(t.dark ? OnTheme.rgb(31, 23, 16) : OnTheme.rgb(250, 243, 232))
        .overlay(alignment: .bottom) { Rectangle().fill(t.line(0.08)).frame(height: 1) }
    }
}

// MARK: - Footer nav (Back / block hint / Continue)

struct OnboardingFooter: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    /// Continue label per step (mock `contLabels`).
    private var continueLabel: LocalizedStringKey {
        switch model.step {
        case .welcome: return "Get started"
        case .models: return model.canContinue ? "Continue" : "Preparing…"
        case .done: return "Finish tour"
        default: return "Continue"
        }
    }

    /// The footer hint. Examples are optional, and the footer says so.
    private var hint: LocalizedStringKey? {
        if !model.canContinue {
            switch model.step {
            case .microphone: return "Allow the microphone to continue"
            case .models: return "Continue unlocks when the models are ready"
            default: return "Finish or cancel the recording first"
            }
        }
        if model.step.isExample { return "Trying the example is optional" }
        if model.step == .done { return "Closing the tour keeps everything you set" }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            if model.showBack {
                Button { model.back() } label: {
                    Text("Back").murFont(14, weight: .semibold).foregroundStyle(t.muted(0.7))
                        .padding(.horizontal, 16).padding(.vertical, 11).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let hint {
                Text(hint).murFont(12.5).foregroundStyle(t.muted(0.5)).lineLimit(1)
            }
            continueButton
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .background(t.footer)
        .overlay(alignment: .top) { Rectangle().fill(t.line(0.09)).frame(height: 1) }
    }

    private var continueButton: some View {
        Button { model.next() } label: {
            Text(continueLabel)
                .murFont(14, weight: .semibold)
                .foregroundStyle(model.canContinue ? OnTheme.rgb(26, 18, 12) : t.muted(0.38))
                .padding(.horizontal, 22).padding(.vertical, 11)
                .background(model.canContinue ? AnyShapeStyle(Mur.accent) : AnyShapeStyle(t.line(0.1)),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canContinue)
    }
}

// MARK: - Finished overlay

struct FinishedOverlay: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(spacing: 6) {
            onboardingCat(104)
                .accessibilityHidden(true)   // decorative
            Text("Murmator is live")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(t.ink).padding(.top, 10)
            Text("Find me up in the menu bar whenever you want to talk.")
                .font(.system(size: 14)).foregroundStyle(t.muted(0.62))
            Button { model.replay() } label: {
                Text("Replay the setup tour")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Mur.accent)
                    .underline()
            }
            .buttonStyle(.plain).padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.overlay)
    }
}
