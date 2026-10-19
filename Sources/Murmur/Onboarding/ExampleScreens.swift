import MurmurKit
import SwiftUI

/// The recording examples: Fast / Hybrid / Accurate, Corrector, Translation and
/// At the caret. Each records with the real session through `OnboardingModel`;
/// none of them changes everyday dictation (the corrector switch is the one
/// Settings switch, and says so).

// MARK: - Shared pieces

/// What the current example runs with: mode, microphone, language, corrector,
/// translation.
private struct ExampleChips: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        ContextChip(label: "Mode", value: modeName(model.practiceMode), accent: true)
        ContextChip(label: "Mic", value: model.microphoneName)
        ContextChip(label: "Language", value: SpeechLanguage.displayName(for: model.practiceLanguage))
        ContextChip(label: "Corrector", value: model.correctorEnabled ? String(localized: "On") : String(localized: "Off"))
        if model.step == .translation, model.practiceTranslationTarget != TranslationSetting.off {
            ContextChip(label: "Translation", value: SpeechLanguage.displayName(for: model.practiceTranslationTarget))
        } else {
            ContextChip(label: "Translation", value: String(localized: "Off"))
        }
    }
}

private func modeName(_ mode: DictationMode) -> String {
    switch mode {
    case .fast: return String(localized: "Fast")
    case .hybrid: return String(localized: "Hybrid")
    case .accurate: return String(localized: "Accurate")
    }
}

/// The stages a take goes through, from the session's own events: what is
/// running now, what has finished, what is switched off, what failed.
private struct PipelineChips: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private enum Stage { case live, accurate, corrector, translation }
    private enum Look { case pending, active, done, off, failed }

    private var stages: [Stage] {
        var out: [Stage] = [.live]
        if model.practiceMode != .fast { out.append(.accurate) }
        out.append(.corrector)
        if model.step == .translation { out.append(.translation) }
        return out
    }

    var body: some View {
        let t = OnTheme(scheme)
        HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                if index > 0 { Text(verbatim: "→").murFont(11).foregroundStyle(t.muted(0.35)).accessibilityHidden(true) }
                chip(stage, t)
            }
            Spacer(minLength: 0)
        }
    }

    private func name(_ stage: Stage) -> LocalizedStringKey {
        switch stage {
        case .live:
            switch model.practiceMode {
            case .fast: return "Live text"
            case .hybrid: return "Live draft"
            case .accurate: return "Recording"
            }
        case .accurate: return "Accurate pass"
        case .corrector: return model.correctorEnabled ? "Corrector" : "Corrector · off"
        case .translation: return "Translation"
        }
    }

    private func order(_ stage: Stage) -> Int {
        switch stage {
        case .live: return 0
        case .accurate: return 1
        case .corrector: return 2
        case .translation: return 3
        }
    }

    /// Index of the stage running now; `Int.max` once the take is finished.
    private var current: Int? {
        switch model.tryPhase {
        case .idle, .preparing: return nil
        case .listening: return 0
        case .finishing(.recognition): return model.practiceMode == .fast ? 0 : 1
        case .finishing(.languageDetection), .finishing(.textEditing): return 2
        case .translating: return 3
        case .done, .failed: return .max
        }
    }

    private func look(_ stage: Stage) -> Look {
        if stage == .corrector, !model.correctorEnabled { return .off }
        if model.tryPhase == .failed, model.tryError != nil, stage == .live { return .failed }
        if stage == .translation, model.tryError != nil, model.tryPhase == .done { return .failed }
        guard let current else { return .pending }
        if current == .max { return .done }
        return order(stage) < current ? .done : (order(stage) == current ? .active : .pending)
    }

    private func chip(_ stage: Stage, _ t: OnTheme) -> some View {
        let look = look(stage)
        let mark = look == .done ? "✓ " : (look == .failed ? "! " : "")
        return (Text(verbatim: mark) + Text(name(stage)))
            .murFont(11.5, weight: .semibold)
            .strikethrough(look == .off)
            .foregroundStyle(look == .active ? Mur.accent : look == .failed ? Mur.error
                             : look == .done ? t.ink : t.muted(look == .off ? 0.42 : 0.5))
            .padding(.horizontal, 8).frame(height: 22)
            .background(look == .active ? Mur.accent.opacity(0.14) : look == .done ? t.line(0.07)
                        : look == .failed ? Mur.error.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Words that differ from `reference` are underlined: what the accurate pass
/// or the corrector changed.
private func marked(_ text: String, against reference: String, ink: Color) -> Text {
    var pool: [String: Int] = [:]
    for word in reference.split(separator: " ") { pool[String(word), default: 0] += 1 }
    var out = Text(verbatim: "")
    for (i, word) in text.split(separator: " ").map(String.init).enumerated() {
        let kept = (pool[word] ?? 0) > 0
        if kept { pool[word]! -= 1 }
        let piece = Text(verbatim: (i > 0 ? " " : "") + word).foregroundColor(ink)
        out = out + (kept || reference.isEmpty ? piece : piece.underline(color: Mur.accent))
    }
    return out
}

/// Live text: settled words in ink, words that may still change in grey.
@MainActor
private func liveText(_ model: OnboardingModel, ink: Color, draft: Color) -> Text {
    Text(verbatim: model.tryConfirmed).foregroundColor(ink)
        + Text(verbatim: model.tryConfirmed.isEmpty || model.tryPartial.isEmpty ? "" : " ")
        + Text(verbatim: model.tryPartial).foregroundColor(draft)
}

/// The press-and-hold button in the 200 × 44 slot, plus "Try again".
private struct HoldToTalk: View {
    @Bindable var model: OnboardingModel
    @State private var pressed = false

    private var ready: Bool { model.tryReady }

    private var title: String {
        if model.tryListening {
            return model.tryMicrophoneLive ? String(localized: "Release to finish") : String(localized: "Opening mic…")
        }
        return model.tryWorking ? String(localized: "Working…") : String(localized: "Hold to talk")
    }

    var body: some View {
        PrimarySlot(title: title, enabled: ready || model.tryListening, live: model.tryMicrophoneLive)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard ready, !pressed else { return }
                    pressed = true
                    model.tryStart()
                }
                .onEnded { _ in
                    guard pressed else { return }
                    pressed = false
                    model.tryEnd()
                })
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hold to talk")
            .accessibilityHint(ready ? "Double-tap to start dictation, double-tap again to stop" : "Models are still loading")
            .accessibilityValue(model.tryListening ? "Listening" : "")
            .accessibilityAction { if ready || model.tryListening { model.tryToggle() } }
        LinkButton(title: "Try again", visible: model.tryPhase == .done || model.tryPhase == .failed || model.tryReleasedEarly) {
            model.tryReset()
        }
    }
}

/// The one-line status of an example and its follow-up link.
private struct ExampleStatus: View {
    @Bindable var model: OnboardingModel
    /// What a finished take means on this step.
    let doneText: String
    @State private var showDetails = false

    var body: some View {
        let status = line
        StatusLine(text: status.text, tone: status.tone)
        if !model.modelsReady {
            LinkButton(title: "Go to Speech models") { model.jump(to: .models) }
        } else if let details = model.tryErrorDetails {
            LinkButton(title: showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                .popover(isPresented: $showDetails) {
                    Text(verbatim: details).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).padding(12).frame(maxWidth: 360)
                }
        }
    }

    private var line: (text: String, tone: StatusTone) {
        let mic = model.microphoneName
        guard model.modelsReady else { return (String(localized: "Speech models aren’t ready yet."), .error) }
        if let error = model.tryError {
            return (error, model.tryPhase == .done ? .working : .error)
        }
        switch model.tryPhase {
        case .idle:
            if model.tryReleasedEarly {
                return (String(localized: "Released too early — nothing was recorded. Hold until the status says Listening."), .neutral)
            }
            return (String(localized: "Ready · \(modeName(model.practiceMode)) · \(mic) · microphone closed"), .neutral)
        case .preparing: return (String(localized: "Opening \(mic)… not listening yet"), .working)
        case .listening: return (String(localized: "Listening · \(mic) · release to finish"), .live)
        case .finishing(.recognition):
            return model.practiceMode == .fast
                ? (String(localized: "Finishing the last words…"), .working)
                : (String(localized: "Accurate pass: re-reading the recording…"), .working)
        case .finishing(.languageDetection): return (String(localized: "Detecting the language for the corrector…"), .working)
        case .finishing(.textEditing): return (String(localized: "Correcting spelling and punctuation…"), .working)
        case .translating:
            return (String(localized: "Translating to \(SpeechLanguage.displayName(for: model.practiceTranslationTarget))…"), .working)
        case .done: return (doneText, .neutral)
        case .failed: return (String(localized: "Something went wrong. Nothing was typed."), .error)
        }
    }
}

/// A titled text box with its own scroll, so long text never moves the page.
private struct TextBox<Content: View>: View {
    let title: LocalizedStringKey
    var accent = false
    var error = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = OnTheme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            Text(title).murFont(12, weight: .semibold)
                .foregroundStyle(accent ? Mur.accent : t.muted(0.7))
                .padding(.horizontal, 14).frame(height: 30)
            Rectangle().fill(t.line(0.08)).frame(height: 1)
            ScrollView {
                content
                    .murFont(16, weight: .medium).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.init(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(error ? Mur.error : (accent ? Mur.accent.opacity(0.4) : t.line(0.1)), lineWidth: 1))
    }
}

private func placeholder(_ key: LocalizedStringKey, _ t: OnTheme) -> some View {
    Text(key).murFont(14).foregroundStyle(t.muted(0.5))
}

// MARK: - Fast / Hybrid / Accurate

struct ModeLessonScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        StepPage(step: model.step, title: title, lede: lede) {
            ExampleChips(model: model)
        } controls: {
            Text("This example uses \(modeName(model.practiceMode)). It doesn’t change your everyday mode — you pick that at the end.")
                .murFont(12.5).foregroundStyle(t.muted(0.72)).lineLimit(2)
        } stage: {
            VStack(spacing: 0) {
                PipelineChips(model: model).padding(.horizontal, 14).frame(height: 36)
                Rectangle().fill(t.line(0.08)).frame(height: 1)
                ScrollView {
                    transcript
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.init(top: 14, leading: 18, bottom: 14, trailing: 18))
                }
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.tryMicrophoneLive ? Mur.accent.opacity(0.6) : t.line(0.1), lineWidth: 1))
        } status: {
            ExampleStatus(model: model, doneText: doneText)
        } action: {
            HoldToTalk(model: model)
        }
    }

    private var title: LocalizedStringKey {
        switch model.step {
        case .fast: return "Fast: words while you speak"
        case .hybrid: return "Hybrid: live draft, then an accurate pass"
        default: return "Accurate: text after you finish"
        }
    }

    private var lede: LocalizedStringKey {
        switch model.step {
        case .fast: return "Hold the button and talk. Words appear as you speak, and the last few may still change. What you see when you release is the result."
        case .hybrid: return "A quick draft appears while you speak. Meanwhile a more accurate model refines it phrase by phrase in the background and finishes the last part when you release."
        default: return "No live text in this mode. Recognition starts when you release, so text appears a moment later. Longer recordings take longer."
        }
    }

    private var doneText: String {
        switch model.step {
        case .fast: return String(localized: "Finished in Fast. This is what was heard live — check it for misheard words.")
        case .hybrid: return String(localized: "Finished. The accurate pass replaced the draft; changed words are underlined. Check the result.")
        default: return String(localized: "Finished in Accurate. Recognition can still make mistakes — read it over.")
        }
    }

    @ViewBuilder private var transcript: some View {
        let ink = t.ink, draft = t.muted(0.5)
        switch model.tryPhase {
        case .listening where model.practiceMode == .accurate:
            HStack(spacing: 12) {
                TourLevelBars(color: Mur.accent, count: 6, barHeight: 22)
                Text("Recording. Accurate shows no words while you speak — text appears after you release.")
                    .murFont(14).foregroundStyle(t.muted(0.74))
            }
        case .listening, .finishing, .translating:
            if model.tryConfirmed.isEmpty, model.tryPartial.isEmpty {
                placeholder(model.tryPhase == .listening ? "Listening… start speaking." : "Recognizing the recording…", t)
            } else {
                liveText(model, ink: model.tryPhase == .listening ? ink : draft, draft: draft).murFont(18, weight: .medium)
            }
        case .done:
            Group {
                if model.step == .hybrid { marked(model.tryConfirmed, against: model.tryDraft, ink: ink) }
                else { Text(verbatim: model.tryConfirmed).foregroundColor(ink) }
            }
            .murFont(18, weight: .medium).textSelection(.enabled)
        case .preparing:
            placeholder("Opening the microphone… keep holding.", t)
        case .failed:
            placeholder("No text from this recording.", t)
        case .idle:
            placeholder(model.practiceMode == .accurate
                        ? "Hold the button, say a sentence, then release. Text appears here after you release."
                        : "Hold the button and say a sentence. Words appear here as you speak.", t)
        }
    }
}

// MARK: - Corrector

struct CorrectorScreen: View {
    @Bindable var model: OnboardingModel
    @AppStorage(OnboardingModel.correctorKey) private var corrector = false
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var correcting: Bool {
        model.tryPhase == .finishing(.languageDetection) || model.tryPhase == .finishing(.textEditing)
    }

    var body: some View {
        StepPage(step: .corrector,
                 title: "Optional corrector",
                 lede: "After recording stops, a local model fixes spelling, grammar and punctuation. It picks its language from the audio, not from your language setting.") {
            ExampleChips(model: model)
        } controls: {
            Toggle(isOn: Binding(get: { corrector }, set: { model.setCorrector($0); corrector = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Correct spelling, grammar and punctuation after recording")
                        .murFont(13, weight: .semibold).foregroundStyle(t.ink).lineLimit(1)
                    Text("Same switch as Settings › Models — applies to all dictation.")
                        .murFont(11.5).foregroundStyle(t.muted(0.62)).lineLimit(1)
                }
            }
            .toggleStyle(.switch).tint(Mur.accent).controlSize(.small)
            .disabled(model.tryListening || model.tryWorking)
        } stage: {
            HStack(spacing: 14) {
                TextBox(title: "Recognized") { recognized }
                TextBox(title: "Corrected", accent: true) { corrected }
            }
        } status: {
            ExampleStatus(model: model, doneText: doneText)
        } action: {
            HoldToTalk(model: model)
        }
    }

    /// The text before the corrector: the session's original when the corrector
    /// changed it, otherwise the final text itself.
    private var before: String { model.tryOriginal.isEmpty ? model.tryConfirmed : model.tryOriginal }
    private var changed: Bool { !model.tryOriginal.isEmpty && model.tryOriginal != model.tryConfirmed }

    private var doneText: String {
        if !corrector { return String(localized: "Finished without correction — the recognized text is what gets typed.") }
        return changed ? String(localized: "Finished. Corrections are underlined — compare with the recognized text.")
                       : String(localized: "Finished. The corrector kept the recognized text as it was.")
    }

    @ViewBuilder private var recognized: some View {
        switch model.tryPhase {
        case .done: Text(verbatim: before).foregroundStyle(t.ink)
        case .listening, .finishing, .translating:
            if model.tryConfirmed.isEmpty, model.tryPartial.isEmpty { placeholder("Listening…", t) }
            else { liveText(model, ink: t.muted(0.6), draft: t.muted(0.45)) }
        default: placeholder("Hold the button and say a sentence.", t)
        }
    }

    @ViewBuilder private var corrected: some View {
        if !corrector {
            placeholder("Corrector is off — the recognized text on the left is what gets typed.", t)
        } else if correcting {
            ProgressView().controlSize(.small)
        } else if model.tryPhase == .done {
            if changed { marked(model.tryConfirmed, against: model.tryOriginal, ink: t.ink) }
            else { placeholder("No changes: the corrector kept the text as recognized.", t) }
        } else {
            placeholder("The corrected text appears here after you stop recording. Changed words are underlined.", t)
        }
    }
}

// MARK: - Translation

struct TranslationScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var targetName: String { SpeechLanguage.displayName(for: model.practiceTranslationTarget) }
    private var hasTarget: Bool { model.practiceTranslationTarget != TranslationSetting.off }
    private var translationTitle: LocalizedStringKey { hasTarget ? "Translation · \(targetName)" : "Translation" }

    var body: some View {
        StepPage(step: .translation,
                 title: "Translate what you said",
                 lede: "Pick a language pair and speak. The recognized text and its translation appear side by side. Both stay on this Mac.") {
            ExampleChips(model: model)
        } controls: {
            Picker("From", selection: $model.practiceLanguage) {
                ForEach(SpeechModelChoice.parakeetLanguages.sorted(), id: \.self) { code in
                    Text(SpeechLanguage.displayName(for: code)).tag(code)
                }
            }
            .fixedSize()
            Picker("To", selection: $model.practiceTranslationTarget) {
                Text("Choose…").tag(TranslationSetting.off)
                ForEach(TranslationSetting.offered(dictating: model.practiceLanguage), id: \.self) { code in
                    Text(SpeechLanguage.displayName(for: code)).tag(code)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("onboarding-translation-target")
            Text("Only for this example.").murFont(12).foregroundStyle(t.muted(0.66)).lineLimit(1)
        } stage: {
            HStack(spacing: 14) {
                TextBox(title: "Recognized") { recognized }
                TextBox(title: translationTitle, accent: true,
                        error: model.tryError != nil && model.tryPhase == .done) { translation }
            }
        } status: {
            ExampleStatus(model: model, doneText: String(localized: "Finished. Translation is machine-made — check names and numbers."))
        } action: {
            HoldToTalk(model: model)
        }
        .onAppear {
            // Translation needs a known source language.
            if model.practiceLanguage == SpeechLanguage.automatic {
                let system = SpeechLanguage.systemDefault
                model.practiceLanguage = system == SpeechLanguage.automatic ? SpeechLanguage.english : system
            }
        }
        .onChange(of: model.practiceLanguage) { _, _ in
            if !TranslationSetting.offered(dictating: model.practiceLanguage).contains(model.practiceTranslationTarget) {
                model.practiceTranslationTarget = TranslationSetting.off
            }
        }
    }

    @ViewBuilder private var recognized: some View {
        switch model.tryPhase {
        case .done: Text(verbatim: model.tryConfirmed).foregroundStyle(t.ink)
        case .listening, .finishing, .translating:
            if model.tryConfirmed.isEmpty, model.tryPartial.isEmpty { placeholder("Listening…", t) }
            else { liveText(model, ink: t.ink, draft: t.muted(0.45)) }
        default: placeholder(hasTarget ? "Hold the button and say a sentence." : "Choose a language to translate to.", t)
        }
    }

    @ViewBuilder private var translation: some View {
        if model.tryPhase == .translating {
            ProgressView().controlSize(.small)
        } else if model.tryPhase == .done, model.tryError != nil {
            Text("This pair didn’t translate. The recognized text on the left is kept. Try again, or pick another pair.")
                .murFont(13).foregroundStyle(t.ink)
        } else if model.tryPhase == .done, !model.tryTranslation.isEmpty {
            Text(verbatim: model.tryTranslation).foregroundStyle(t.ink)
                .accessibilityIdentifier("onboarding-translation-result")
        } else if hasTarget {
            placeholder("The \(targetName) translation appears here after recognition finishes.", t)
        } else {
            placeholder("No language chosen: nothing is translated.", t)
        }
    }
}

// MARK: - At the caret

struct CaretLessonScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }

    var body: some View {
        StepPage(step: .caret,
                 title: "Dictate where you’re typing",
                 lede: "Click in the text to set the insertion point. Tap right ⌘ once and speak — no need to hold. Return inserts the text there, Escape cancels.") {
            ExampleChips(model: model)
        } controls: {
            keycap("right ⌘", "tap · start", active: !model.tryListening)
            keycap("Return", "insert", active: model.tryMicrophoneLive)
            keycap("Esc", "cancel", active: model.tryListening)
            Spacer(minLength: 0)
            Text("Or hold right ⌘: talk while holding, release inserts.")
                .murFont(11.5).foregroundStyle(t.muted(0.6)).multilineTextAlignment(.trailing)
                .frame(maxWidth: 170, alignment: .trailing)
        } stage: {
            VStack(alignment: .leading, spacing: 0) {
                (Text("Practice field") + Text(verbatim: " · ").foregroundColor(t.muted(0.4))
                    + Text("a real text field; nothing leaves this window").foregroundColor(t.muted(0.5)))
                    .murFont(12, weight: .semibold).foregroundStyle(t.muted(0.7))
                    .padding(.horizontal, 14).frame(height: 30)
                Rectangle().fill(t.line(0.08)).frame(height: 1)
                CaretDemoEditor(text: $model.demoText, selection: $model.demoSelection,
                                editable: !model.tryListening && !model.tryWorking,
                                onMake: { model.demoTextView = $0 })
                    .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.caretNeedsFocus ? Mur.accent : t.line(0.1), lineWidth: model.caretNeedsFocus ? 2 : 1))
        } status: {
            caretStatus
        } action: {
            PrimarySlot(title: slotTitle, live: model.tryMicrophoneLive, plain: !model.tryMicrophoneLive)
                .accessibilityLabel(Text(verbatim: slotTitle))
            LinkButton(title: "Grant Accessibility…", visible: !model.flow.accessibilityGranted) { model.promptAccessibility() }
        }
        .onAppear { model.refreshPermissions() }
        .onChange(of: model.demoSelection) { _, _ in model.clearCaretFocusHint() }
    }

    private var slotTitle: String {
        if model.tryMicrophoneLive { return String(localized: "Listening") }
        if model.tryListening { return String(localized: "Getting ready…") }
        if model.tryWorking { return String(localized: "Finishing…") }
        return String(localized: "Waiting for right ⌘")
    }

    @ViewBuilder private var caretStatus: some View {
        let mic = model.microphoneName
        if !model.flow.accessibilityGranted {
            StatusLine(text: String(localized: "Right ⌘ needs Accessibility access to work in any app."), tone: .working)
        } else if model.caretNeedsFocus {
            StatusLine(text: String(localized: "Click in the practice field first, so I know where to insert."), tone: .working)
        } else if model.tryError != nil {
            ExampleStatus(model: model, doneText: "")
        } else if model.tryMicrophoneLive {
            StatusLine(text: String(localized: "Listening · \(mic) · Return inserts, Esc cancels"), tone: .live)
        } else if model.tryListening {
            StatusLine(text: String(localized: "Right ⌘ received · opening the microphone · Esc cancels"), tone: .working)
        } else if model.tryWorking {
            StatusLine(text: String(localized: "Finishing… the text goes in at the insertion point when ready"), tone: .working)
        } else if model.tryCancelled {
            StatusLine(text: String(localized: "Cancelled. Nothing was inserted."))
        } else if model.tryPhase == .done {
            StatusLine(text: String(localized: "Inserted at the insertion point. Check it, then try again or continue."))
        } else {
            StatusLine(text: String(localized: "Click in the text, then tap right ⌘ · microphone closed"))
        }
    }

    private func keycap(_ key: String, _ action: LocalizedStringKey, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: key).murFont(12, weight: .semibold).foregroundStyle(t.ink)
            Text(action).murFont(12).foregroundStyle(t.muted(0.7))
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(active ? Mur.accent.opacity(0.14) : t.line(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(active ? Mur.accent.opacity(0.4) : t.line(0.16), lineWidth: 1))
    }
}
