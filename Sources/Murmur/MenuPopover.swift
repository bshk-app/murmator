import AppKit
import MurmurKit
import SwiftUI

/// The menu bar panel (design: Claude Design «Murmator Mac Controls v4», after
/// MurMur.dc.html's menu bar dropdown): what people change between dictations,
/// and the way to the window and Settings. Hotkey, HUD, captions and model
/// memory live in the window.
struct MenuPopover: View {
    let dictation: DictationController
    let onOpenWindow: () -> Void
    let onSettings: () -> Void
    let onToggleDictation: () -> Void
    @Environment(\.colorScheme) private var scheme

    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(AppMode.defaultsKey) private var appModeRaw = AppMode.dictation.rawValue
    @AppStorage(ModelSetting.key) private var modelRaw = DictationMode.hybrid.rawValue
    @AppStorage(SpeechLanguage.defaultsKey) private var languageRaw = SpeechLanguage.systemDefault
    @AppStorage(TranslationSetting.key) private var translateToRaw = TranslationSetting.off
    @AppStorage(MicrophoneSetting.defaultsKey) private var microphoneUID = MicrophoneSetting.systemDefaultUID
    @AppStorage(ControlSettingsObserver.correctorKey) private var corrector = false

    private var palette: MacPalette { MacPalette(scheme) }
    private var captions: Bool { appModeRaw == AppMode.captions.rawValue }
    private var locked: Bool { !dictation.canChangeModels }

    var body: some View {
        VStack(spacing: 0) {
            head
            if let alert = ControlsAlert.current(dictation) {
                ControlsBanner(title: alert.title, message: alert.message, actionTitle: alert.actionTitle,
                               isError: alert.isError) { alert.perform(dictation) }
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
            if dictation.isManagingModels { preparation }
            Group {
                if dictation.state == .recording { levelRow }
                section { microphone }
                section { model }
                section { languagePair }
                section { correctorRow }
            }
            footer
        }
        .frame(width: 296)
        .background(palette.panel)
        .onAppear { _ = dictation.refreshMicrophones(preferredUID: microphoneUID) }
    }

    // MARK: head

    private var head: some View {
        let status = ControlsStatus.current(dictation, detailed: false)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                MurmatorMascot(mood: status.tone == .error ? .error : .idle, size: 23)
                    .frame(width: 30, height: 30)
                    .background(MacPalette.rgb(36, 31, 28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 1))
                Text(verbatim: "Murmator").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("Dictation on", isOn: $enabled)
                    .toggleStyle(.switch).tint(Mur.accent).labelsHidden()
                    .accessibilityLabel("Dictation on")
            }
            HStack(spacing: 8) {
                StatusDot(tone: status.tone)
                Text(verbatim: status.text)
                    .font(.system(size: 12.5, weight: status.tone == .error ? .semibold : .regular))
                    .foregroundStyle(status.tone == .error ? palette.errorText : palette.note)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                ShortcutChip(bordered: true) { dictation.triggerLabel }
            }
            .padding(.top, 10)
            PrimaryDictationButton(action: PrimaryDictationAction.current(dictation), perform: onToggleDictation)
                .padding(.top, 12)
        }
        .padding(.init(top: 14, leading: 15, bottom: 12, trailing: 15))
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: dictation.modelPreparation?.fraction)
                .progressViewStyle(.linear).tint(Mur.accent)
            Text(verbatim: dictation.modelPreparationStatus)
                .font(.system(size: 12)).foregroundStyle(palette.note)
        }
        .padding(.horizontal, 15).padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: settings

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    private var levelRow: some View {
        HStack(spacing: 11) {
            Text("Microphone").font(.system(size: 12)).foregroundStyle(palette.label).frame(width: 74, alignment: .leading)
            InputLevelBars()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }

    @ViewBuilder private var microphone: some View {
        FieldLabel(title: "Microphone")
        MurPopup(label: "Microphone", selection: MicrophoneChoice.binding($microphoneUID, devices: dictation.microphones),
                 options: [MicrophoneSetting.systemDefaultUID] + dictation.microphones.map(\.uid),
                 title: { uid in
                     uid == MicrophoneSetting.systemDefaultUID
                         ? String(localized: "System default")
                         : dictation.microphones.first { $0.uid == uid }?.name ?? uid
                 })
            .disabled(locked)
    }

    @ViewBuilder private var model: some View {
        FieldLabel(title: "Model")
        MurSegment(label: "Model", selection: $modelRaw, options: ControlsChoices.modes(for: languageRaw))
            .disabled(locked)
    }

    @ViewBuilder private var languagePair: some View {
        HStack(alignment: .bottom, spacing: 9) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "Language")
                MurPopup(label: "Language", selection: $languageRaw,
                         options: ControlsChoices.languages(dictation, including: languageRaw),
                         title: SpeechLanguage.displayName(for:))
                    .disabled(locked)
            }
            Text(verbatim: "→").font(.system(size: 12)).foregroundStyle(palette.faint).padding(.bottom, 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "Translate to")
                MurPopup(label: "Translate to", selection: $translateToRaw,
                         options: ControlsChoices.targets(dictating: languageRaw),
                         title: ControlsChoices.targetName)
                    .disabled(dictation.isActive || languageRaw == SpeechLanguage.automatic)
            }
        }
        .onChange(of: languageRaw) {
            if !ControlsChoices.targets(dictating: languageRaw).contains(translateToRaw) {
                translateToRaw = TranslationSetting.off
            }
        }
    }

    private var correctorRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Corrector").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink)
                Text(captions ? "Not used for captions." : "Fixes spelling and punctuation after you stop")
                    .font(.system(size: 12)).foregroundStyle(palette.note)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Corrector", isOn: $corrector)
                .toggleStyle(.switch).controlSize(.small).tint(Mur.accent).labelsHidden()
        }
        .disabled(dictation.isActive || captions)
        .accessibilityElement(children: .combine)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            if !dictation.lastOutputText.isEmpty {
                PanelCommand(title: "Copy Last Dictation", key: "", action: dictation.copyLastDictation)
            }
            PanelCommand(title: "Open Murmator Window", key: "", action: onOpenWindow)
            PanelCommand(title: "Settings…", key: "⌘ ,", action: onSettings)
                .keyboardShortcut(",")
            PanelCommand(title: "Quit Murmator", key: "⌘ Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 1) }
    }
}

/// A menu-like row at the bottom of the panel.
private struct PanelCommand: View {
    let title: LocalizedStringKey
    let key: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let palette = MacPalette(scheme)
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(palette.ink)
                Spacer()
                Text(verbatim: key).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(palette.faint)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovered ? palette.field : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
