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

/// Shared mascot artwork; the rail adds its own narrator bounce on top.
func onboardingCat(_ size: CGFloat) -> some View {
    MurmatorMascot(mood: .idle, size: size)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-step narrator copy (mock `narration[]`). These English strings are the
    /// String-Catalog keys (already translated in `Localizable.xcstrings`); resolved
    /// at runtime for the typewriter via `Bundle.localizedString`.
    private static let narration: [String] = [
        "Hi, I’m Murmator! Hold a key, talk, and I type the words right where your cursor is. Ready to set me up?",
        "I need two macOS permissions to work. Tap each one — I’ll tell you exactly why.",
        "Pick the keys you’ll hold while you talk. Record your own combo, or grab a preset.",
        "Hang tight — I’m downloading my voice. This is the only big download, ever.",
        "Your turn! Press and hold the button and say something. Watch me catch up and tidy it.",
        "All done — I’ll wait up in your menu bar until you need me. Just hold your keys and talk.",
    ]

    private var t: OnTheme { OnTheme(scheme) }

    @State private var floatUp = false           // gentle continuous bob
    @State private var talk = false              // bounce pulse on each new line
    @State private var typed = ""                // typewriter-revealed narration
    @State private var typing = false
    @State private var typeTask: Task<Void, Never>?
    @State private var fullLine = ""             // resolved full narration line (VoiceOver label)

    var body: some View {
        VStack(spacing: 0) {
            onboardingCat(96)
                .scaleEffect(talk ? 1.07 : 1)
                .rotationEffect(.degrees(talk ? -3 : 0))
                .offset(y: floatUp ? -6 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: floatUp)
                .padding(.bottom, 12)
                .accessibilityHidden(true)   // decorative; the narrator text carries the info
            narratorBubble
            Spacer(minLength: 0)
            Text("Setup steps")
                .tracking(1.4).murFont(10.5, weight: .bold)
                .foregroundStyle(t.muted(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 11)
            stepper
        }
        .padding(.init(top: 26, leading: 24, bottom: 22, trailing: 24))
        .frame(width: 296)
        .background(t.stage)
        .overlay(alignment: .trailing) {
            Rectangle().fill(t.line(0.08)).frame(width: 1)
        }
        .onAppear { floatUp = true; speak() }
        .onChange(of: model.flow.step) { _, _ in speak() }
    }

    /// Bounce the cat and type the new line out, character by character — so each
    /// step reads as the cat actually saying it.
    private func speak() {
        if !reduceMotion {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { talk = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { talk = false }
            }
        }
        let key = Self.narration[model.flow.step.rawValue]
        let full = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        fullLine = full
        typeTask?.cancel()
        if reduceMotion {
            typed = full; typing = false; return    // no bounce, no typewriter
        }
        typed = ""
        typing = true
        typeTask = Task { @MainActor in
            for ch in full {
                if Task.isCancelled { return }
                typed.append(ch)
                try? await Task.sleep(for: .milliseconds(18))
            }
            typing = false
        }
    }

    /// Trailing accent caret while the line is still typing out.
    private var caret: Text {
        typing ? Text(verbatim: "▏").foregroundColor(Mur.accent) : Text(verbatim: "")
    }

    private var narratorBubble: some View {
        (Text(verbatim: typed) + caret)
            .murFont(13.5).lineSpacing(4)
            .foregroundStyle(t.muted(0.96))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
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
            .accessibilityLabel(Text(verbatim: fullLine))
            .accessibilityHint("Setup narration")
    }

    private var stepper: some View {
        let labels: [LocalizedStringKey] = ["Welcome", "Permissions", "Shortcut", "Download", "Try it", "Done"]
        let current = model.flow.step.rawValue
        return VStack(spacing: 3) {
            ForEach(0 ..< labels.count, id: \.self) { i in
                let done = i < current, active = i == current
                HStack(spacing: 11) {
                    stepDot(index: i, done: done, active: active)
                    Text(labels[i])
                        .murFont(13, weight: active ? .semibold : .medium)
                        .foregroundStyle(active ? t.ink : (done ? t.muted(0.72) : t.muted(0.45)))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup steps")
        .accessibilityValue("Step \(current + 1) of \(labels.count)")
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
                Text("✓").font(.system(size: 11, weight: .bold)).foregroundStyle(OnTheme.rgb(26, 18, 12))
            } else {
                Text("\(index + 1)").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Mur.accent : t.muted(0.42))
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Title bar (traffic lights + centered title)

struct OnboardingTitleBar: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var titleLabel: LocalizedStringKey {
        if model.finished { return "Done" }
        switch model.flow.step {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .shortcut: return "Shortcut"
        case .download: return "Download"
        case .tryIt: return "Try it"
        case .done: return "Done"
        }
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
        switch model.flow.step {
        case .welcome: return "Get started"
        case .permissions, .shortcut: return "Continue"
        case .download: return model.canContinue ? "Continue" : "Downloading…"
        case .tryIt: return "I’ve got it"
        case .done: return "Start using Murmator"
        }
    }

    /// Hint shown next to a disabled Continue (mock `blockHint`).
    private var blockHint: LocalizedStringKey? {
        guard !model.canContinue else { return nil }
        switch model.flow.step {
        case .permissions: return "Grant the microphone to continue"
        case .tryIt: return "Hold the button and speak to try it"
        default: return nil
        }
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
            if let hint = blockHint {
                Text(hint).murFont(12.5).foregroundStyle(t.muted(0.5))
            }
            continueButton
        }
        .padding(.horizontal, 30).padding(.vertical, 15)
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
