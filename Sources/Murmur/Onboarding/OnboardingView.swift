import MurmurKit
import SwiftUI

/// The first-run onboarding window (design: MurMur Onboarding.dc.html). A 6-step
/// wizard: title bar + left narrator rail + a right content pane that switches on
/// `OnboardingFlow.Step`, with a Back/Continue footer gated by `model.canContinue`.
/// All six steps are real (mic/accessibility, shortcut, live download, in-window
/// try-it). Theme-adaptive via `OnTheme`.
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
                        ScrollView {
                            content.padding(.init(top: 30, leading: 36, bottom: 26, trailing: 36))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
        switch model.flow.step {
        case .welcome:     WelcomeScreen()
        case .permissions: PermissionsScreen(model: model)   // Phase 2
        case .shortcut:    ShortcutScreen(model: model)       // Phase 2
        case .download:    DownloadScreen(model: model)       // Phase 3
        case .tryIt:       TryItScreen(model: model)          // Phase 4
        case .done:        DoneScreen(model: model)
        }
    }
}

// MARK: - Shared screen header (eyebrow + serif title + lede)

private struct ScreenHeader: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let lede: LocalizedStringKey
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .tracking(1.4).murFont(11, weight: .bold)
                .foregroundStyle(Mur.accent)
            Text(title)
                .murFont(32, weight: .semibold, design: .serif)
                .foregroundStyle(t.ink).padding(.top, 10)
            Text(lede)
                .murFont(14.5).lineSpacing(4)
                .foregroundStyle(t.muted(0.66))
                .frame(maxWidth: 444, alignment: .leading).padding(.top, 11)
        }
    }
}

// MARK: - Step 0: Welcome (full)

private struct WelcomeScreen: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                eyebrow: "Welcome",
                title: "Just talk. I’ll type it.",
                lede: "A little menu-bar cat that turns your voice into text — instantly, in any app, completely on your Mac. Let’s get you set up in a minute.")

            HStack(spacing: 11) {
                featureCard(badge: { keyBadge("⌥ Space") },
                            title: "Hold the keys", caption: "One global shortcut, anywhere.")
                featureCard(badge: { speakBadge },
                            title: "Speak naturally", caption: "Real-time, no spinner.")
                featureCard(badge: { typedBadge },
                            title: "It’s typed for you", caption: "Straight into the field.")
            }
            .padding(.top, 22)

            modelsNote.padding(.top, 16)
            consentToggle.padding(.top, 12)
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

    private func featureCard<Badge: View>(@ViewBuilder badge: () -> Badge,
                                           title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            badge()
            Text(title).murFont(13.5, weight: .semibold).foregroundStyle(t.ink).padding(.top, 11)
            Text(caption).murFont(12).lineSpacing(2).foregroundStyle(t.muted(0.58)).padding(.top, 4)
                .lineLimit(2, reservesSpace: true)   // reserve 2 lines so all 3 cards match height
        }
        .padding(.init(top: 15, leading: 14, bottom: 15, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(t.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private func keyBadge(_ s: String) -> some View {
        Text(verbatim: s).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
            .padding(.horizontal, 11).frame(height: 30)
            .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
            .accessibilityHidden(true)   // illustrative chip; the card title/caption carry meaning
    }

    private var speakBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(Mur.accent).frame(width: 7, height: 7)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Capsule().fill(Mur.accent).frame(width: 2.5, height: 13)
                }
            }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Mur.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Mur.accent.opacity(0.2), lineWidth: 1))
        .accessibilityHidden(true)   // illustrative chip; the card title/caption carry meaning
    }

    private var typedBadge: some View {
        HStack(spacing: 1) {
            Text("text appears").font(.system(size: 13)).foregroundStyle(t.ink)
            Rectangle().fill(Mur.accent).frame(width: 1.5, height: 14)
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
        .accessibilityHidden(true)   // illustrative chip; the card title/caption carry meaning
    }

    /// Size pulled from `OnboardingFlow`.
    private var modelsNote: some View {
        let gb = String(format: "%.1f GB", OnboardingFlow.totalGB)
        let body = Text("Two models, one trick. ").fontWeight(.bold).foregroundColor(t.ink)
            + Text("A fast model types an instant draft while you speak. When you release, an accurate model rewrites the whole utterance. Setup installs both — about ")
            + Text(verbatim: gb).fontWeight(.bold).foregroundColor(t.ink)
            + Text(". Nothing you say ever leaves your Mac.")
        return HStack(alignment: .top, spacing: 11) {
            onboardingCat(30).padding(.top, 1).accessibilityHidden(true)   // decorative
            body.font(.system(size: 13)).lineSpacing(3).foregroundColor(t.muted(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(Mur.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mur.accent.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Step 5: Done (full)

private struct DoneScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                eyebrow: "All set",
                title: "You’re ready to talk",
                lede: "Murmator is now living quietly in your menu bar. Hold your shortcut in any app and just talk — the words land right where your cursor is.")

            VStack(spacing: 9) {
                checkRow(title: "Two voice models installed",
                         trailing: { (Text(verbatim: String(format: "%.1f GB · ", OnboardingFlow.totalGB)) + Text("on-device"))
                             .font(.system(size: 12.5)).foregroundStyle(t.muted(0.5)) })
                permissionRow
                checkRow(title: "Shortcut set to",
                         trailing: { keyChips(model.shortcutLabel) })
            }
            .padding(.top, 22)
        }
    }

    /// Honest permission row: a green check when Accessibility is granted, an amber
    /// "typing off" notice when it was skipped (Accessibility is optional — HUD-only
    /// dictation still works; the user can grant it later from the menu).
    @ViewBuilder private var permissionRow: some View {
        if model.flow.accessibilityGranted {
            checkRow(title: "Microphone & Accessibility granted", trailing: { EmptyView() })
        } else {
            row(badge: noticeBadge, title: "Typing into other apps is off — grant Accessibility later from the menu",
                tint: amber, trailing: { EmptyView() })
        }
    }

    private func checkRow<Trailing: View>(title: LocalizedStringKey,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        row(badge: checkBadge, title: title, tint: t.ink, trailing: trailing)
    }

    private func row<Badge: View, Trailing: View>(badge: Badge, title: LocalizedStringKey, tint: Color,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            badge
            Text(title).murFont(14, weight: .medium).foregroundStyle(tint)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.init(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(t.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line(0.1), lineWidth: 1))
    }

    private var amber: Color { OnTheme.rgb(244, 191, 79) }

    private var checkBadge: some View {
        Circle().fill(OnTheme.rgb(95, 179, 106)).frame(width: 22, height: 22)
            .overlay(Text("✓").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .accessibilityHidden(true)   // decorative; the row title carries the meaning
    }

    /// Amber "!" badge for the skipped-Accessibility (typing-off) notice.
    private var noticeBadge: some View {
        Circle().fill(amber).frame(width: 22, height: 22)
            .overlay(Text(verbatim: "!").font(.system(size: 13, weight: .bold)).foregroundStyle(OnTheme.rgb(26, 18, 12)))
            .accessibilityHidden(true)   // decorative; the row title carries the meaning
    }

    private func keyChips(_ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(splitShortcut(label), id: \.self) { key in
                Text(verbatim: key).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(t.ink)
                    .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                    .background(t.line(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(t.line(0.14), lineWidth: 1))
            }
        }
    }

    /// Split a shortcut label ("⌃⌥Space") into chip tokens. KeyboardShortcuts
    /// renders modifiers glyph-adjacent; break before the trailing key name.
    private func splitShortcut(_ s: String) -> [String] {
        let mods = Set("⌃⌥⇧⌘")
        var out: [String] = []
        var key = ""
        for ch in s where ch != " " {
            if mods.contains(ch) { out.append(String(ch)) } else { key.append(ch) }
        }
        if !key.isEmpty { out.append(key) }
        return out.isEmpty ? [s] : out
    }
}

