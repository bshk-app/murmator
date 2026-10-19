import MurmurKit
import SwiftUI

/// The tour window (design: Murmator Mac Tour v3.dc.html). Title bar + guide rail
/// + a content pane that switches on `OnboardingFlow.Step`, with a Back/Continue
/// footer. The pane never scrolls: every step is a `StepPage` of fixed zones, and
/// only long text scrolls inside its own box.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                OnboardingTitleBar(model: model)
                HStack(spacing: 0) {
                    OnboardingRail(model: model)
                    VStack(spacing: 0) {
                        content
                            .padding(.init(top: 22, leading: 32, bottom: 14, trailing: 32))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if !model.finished { OnboardingFooter(model: model) }
                    }
                    .background(t.surface)
                }
            }
            if model.finished { FinishedOverlay(model: model) }
        }
        .background(t.surface)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:     WelcomeScreen()
        case .microphone:  MicrophoneScreen(model: model)
        case .models:      ModelsScreen(model: model)
        case .fast, .hybrid, .accurate: ModeLessonScreen(model: model)
        case .corrector:   CorrectorScreen(model: model)
        case .translation: TranslationScreen(model: model)
        case .caret:       CaretLessonScreen(model: model)
        case .done:        DoneScreen(model: model)
        }
    }
}

// MARK: - Fixed page zones

/// One tour page: header, context strip, controls, stage, status and action
/// rows, each with a fixed height, so no control moves when the text inside a
/// zone changes.
struct StepPage<Strip: View, Controls: View, Stage: View, Status: View, Action: View>: View {
    let step: OnboardingFlow.Step
    let title: LocalizedStringKey
    let lede: LocalizedStringKey
    @ViewBuilder var strip: Strip
    @ViewBuilder var controls: Controls
    @ViewBuilder var stage: Stage
    @ViewBuilder var status: Status
    @ViewBuilder var action: Action
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                (Text("Step \(step.rawValue + 1) of \(OnboardingFlow.Step.allCases.count)")
                    + Text(verbatim: " · ") + Text(step.title))
                    .tracking(1.2).murFont(11, weight: .bold)
                    .foregroundStyle(Mur.accent)
                Text(title)
                    .murFont(25, weight: .semibold, design: .serif)
                    .foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 8)
                Text(lede)
                    .murFont(13.5).lineSpacing(2)
                    .foregroundStyle(t.muted(0.7))
                    .lineLimit(2, reservesSpace: true)
                    .padding(.top, 7)
            }
            .frame(height: 96, alignment: .topLeading)
            HStack(spacing: 6) { strip }.frame(height: 28, alignment: .leading)
            HStack(spacing: 12) { controls }.frame(height: 40, alignment: .leading)
            stage.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) { status }.frame(height: 22, alignment: .leading)
            HStack(spacing: 16) { action }.frame(height: 44, alignment: .leading)
        }
    }
}

/// How a status line reads. "Done" is neutral on purpose: finishing does not
/// mean the text is right.
enum StatusTone { case neutral, working, live, ok, error }

struct StatusLine: View {
    let text: String
    var tone: StatusTone = .neutral
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
                .background(Circle().fill(tone == .live ? OnTheme.rgb(224, 83, 61, 0.22) : .clear).frame(width: 14, height: 14))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .murFont(12.5, weight: tone == .error ? .semibold : .medium)
                .foregroundStyle(tone == .error ? Mur.error : (tone == .neutral ? t.muted(0.72) : t.ink))
                .lineLimit(1).truncationMode(.tail)
        }
    }

    private var dot: Color {
        switch tone {
        case .neutral: return t.muted(0.4)
        case .working: return Mur.accent
        case .live: return OnTheme.rgb(224, 83, 61)
        case .ok: return t.ok
        case .error: return Mur.error
        }
    }
}

/// A plain text action next to the status or the primary button.
struct LinkButton: View {
    let title: LocalizedStringKey
    var visible = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).murFont(12.5, weight: .semibold).foregroundStyle(Mur.accent)
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }
}

/// The 200 × 44 primary slot. Label changes never change its size.
struct PrimarySlot: View {
    let title: String
    var enabled = true
    var live = false
    var plain = false
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        HStack(spacing: 9) {
            if live { TourLevelBars(color: .white) }
            Text(verbatim: title).murFont(14, weight: .semibold).lineLimit(1)
        }
        .foregroundStyle(live ? .white : (plain ? t.ink : OnTheme.rgb(36, 31, 28)))
        .frame(width: 200, height: 44)
        .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(enabled ? 1 : 0.38)
    }

    private var fill: AnyShapeStyle {
        if live { return AnyShapeStyle(OnTheme.rgb(224, 83, 61)) }
        if plain { return AnyShapeStyle(t.line(0.1)) }
        return AnyShapeStyle(Mur.accent)
    }
}

/// A small fact about the current example (mode, microphone, corrector…).
struct ContextChip: View {
    let label: LocalizedStringKey
    let value: String
    var accent = false
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        (Text(label).foregroundColor(t.muted(0.6)) + Text(verbatim: " " + value))
            .murFont(11.5, weight: .semibold)
            .foregroundStyle(accent ? Mur.accent : t.ink)
            .lineLimit(1)
            .padding(.horizontal, 9).frame(height: 24)
            .background(accent ? Mur.accent.opacity(0.14) : t.line(0.07),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Animated level bars (mirrors the HUD's `LevelBars`): the microphone is open.
struct TourLevelBars: View {
    var color: Color
    var count: Int = 4
    var barHeight: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: barHeight)
                    .scaleEffect(y: (up || reduceMotion) ? 1 : 0.32, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .accessibilityHidden(true)   // decorative meter
        .onAppear { up = true }
    }
}

// MARK: - Welcome

private struct WelcomeScreen: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        StepPage(step: .welcome,
                 title: "Just talk. I’ll type it.",
                 lede: "This tour teaches the real app, one action per step. Everything runs on your Mac.") {
            Text("About five minutes. Every example is optional.").murFont(12.5).foregroundStyle(t.muted(0.62))
        } controls: {
            EmptyView()
        } stage: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    featureCard(badge: "right ⌘", title: "Tap right ⌘", caption: "Start dictating in any app.")
                    featureCard(badge: "Fast · Hybrid · Accurate", title: "Pick a mode", caption: "Live text, or more accurate text after you stop.")
                    featureCard(badge: "⏎ / Esc", title: "Insert or cancel", caption: "Return types the text, Escape throws it away.")
                }
                consentToggle
            }
        } status: {
            EmptyView()
        } action: {
            EmptyView()
        }
    }

    /// Opt-in analytics consent (off by default). Surfaced up front so the choice is
    /// made before any event fires; flipping it opts in/out of PostHog immediately.
    private var consentToggle: some View {
        Toggle(isOn: $analyticsEnabled) {
            Text("Share anonymous usage & crash reports — never your audio or transcripts. Optional, change anytime in Settings.")
                .murFont(12).lineSpacing(2).foregroundStyle(t.muted(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch).tint(Mur.accent).controlSize(.small)
        .onChange(of: analyticsEnabled) { _, on in
            AnalyticsConsent.set(on)
        }
        .padding(.init(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(t.line(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(t.line(0.08), lineWidth: 1))
    }

    private func featureCard(badge: String, title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: badge).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.ink).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 9).frame(height: 26)
                .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title).murFont(13.5, weight: .semibold).foregroundStyle(t.ink).padding(.top, 10)
            Text(caption).murFont(12).lineSpacing(2).foregroundStyle(t.muted(0.6)).padding(.top, 4)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.init(top: 13, leading: 13, bottom: 13, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(t.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }
}

// MARK: - Done

private struct DoneScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var everyday: DictationMode { model.everyday ?? ModelSetting.current }

    var body: some View {
        StepPage(step: .done,
                 title: "Ready to dictate",
                 lede: "Pick the mode for everyday dictation. Everything here can be changed later from the menu bar.") {
            Text("Translation stays off for everyday dictation unless you turn it on.")
                .murFont(12.5).foregroundStyle(t.muted(0.62))
        } controls: {
            Text("Everyday mode").murFont(13, weight: .semibold).foregroundStyle(t.ink)
            Picker("Everyday mode", selection: Binding(get: { everyday }, set: { model.everyday = $0 })) {
                Text("Fast").tag(DictationMode.fast)
                Text("Hybrid").tag(DictationMode.hybrid)
                Text("Accurate").tag(DictationMode.accurate)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text(modeNote).murFont(12).foregroundStyle(t.muted(0.66)).lineLimit(1)
        } stage: {
            VStack(spacing: 0) {
                row("Microphone", model.microphoneName)
                row("Shortcut", String(localized: "Tap right ⌘ to dictate at the caret · hold it to talk, release to insert"))
                row("Corrector", model.correctorEnabled
                    ? String(localized: "On for all dictation — Settings › Models")
                    : String(localized: "Off — Settings › Models"))
                row("Translation", String(localized: "Off for everyday dictation — menu bar › Translate to"))
                row("This tour", String(localized: "Menu bar icon › Setup tour…"), last: true)
            }
            .padding(.horizontal, 16)
            .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
        } status: {
            if !model.flow.accessibilityGranted {
                StatusLine(text: String(localized: "Typing into other apps needs Accessibility — grant it from the menu later."), tone: .working)
            } else {
                StatusLine(text: String(localized: "Microphone and Accessibility are allowed."), tone: .ok)
            }
        } action: {
            EmptyView()
        }
    }

    private var modeNote: LocalizedStringKey {
        switch everyday {
        case .fast: return "Text while you speak; least accurate."
        case .hybrid: return "Live draft, then an accurate result."
        case .accurate: return "Text after you finish; no live draft."
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String, last: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(key).murFont(12.5, weight: .semibold).foregroundStyle(t.muted(0.7))
                .frame(width: 104, alignment: .leading)
            Text(verbatim: value).murFont(13).foregroundStyle(t.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(t.line(0.07)).frame(height: 1) } }
    }
}
