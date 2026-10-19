import AppKit
@preconcurrency import AVFoundation
import KeyboardShortcuts
import MurmurKit
import PostHog
import SwiftUI

/// The Murmator window (design: Claude Design «Murmator Mac Controls v4»,
/// after Murmator Mac Advisor and Window.dc.html). Status lives in the window
/// subtitle and the one primary action in the toolbar; below, cards of rows
/// with the label on the leading side. The owner hosts it with title and
/// toolbar bridging; closing the window keeps dictation running.
struct MainControlView: View {
    let dictation: DictationController
    let onSettings: () -> Void
    /// Settings, scrolled to cloud providers and per-step models.
    var onProviders: (() -> Void)? = nil
    var onToggleDictation: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(AppMode.defaultsKey) private var appModeRaw = AppMode.dictation.rawValue
    @AppStorage(TriggerMode.defaultsKey) private var triggerRaw = TriggerMode.hold.rawValue
    @AppStorage(ModelSetting.key) private var modelRaw = DictationMode.hybrid.rawValue
    @AppStorage(SpeechLanguage.defaultsKey) private var languageRaw = SpeechLanguage.systemDefault
    @AppStorage(TranslationSetting.key) private var translateToRaw = TranslationSetting.off
    @AppStorage(MicrophoneSetting.defaultsKey) private var microphoneUID = MicrophoneSetting.systemDefaultUID
    @AppStorage(CaptionsDisplay.defaultsKey) private var captionsDisplay = CaptionsDisplay.followCursor
    @AppStorage(RightCommandTrigger.key) private var rightCommand = true
    @AppStorage(HUDStyle.defaultsKey) private var hudStyle: HUDStyle = .caret
    @AppStorage(ControlSettingsObserver.correctorKey) private var corrector = false

    @State private var screensGeneration = 0
    @State private var showingCaptionsAppearance = false
    @State private var shortcutClash: SystemShortcutClash?
    @State private var showTranslationDetails = false

    private var palette: MacPalette { MacPalette(scheme) }
    private var captions: Bool { appModeRaw == AppMode.captions.rawValue }
    private var locked: Bool { !dictation.canChangeModels }

    var body: some View {
        let status = ControlsStatus.current(dictation, detailed: true)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let alert = ControlsAlert.current(dictation) {
                    ControlsBanner(title: alert.title, message: alert.message, actionTitle: alert.actionTitle,
                                   isError: alert.isError) { alert.perform(dictation) }
                }
                card("Dictation") {
                    row("Microphone") { microphoneRow }
                    if dictation.state == .recording { row("Input level") { InputLevelBars() } }
                    row("Model") { modelRow }
                    row("Language") { languageRow }
                    row("Corrector", last: true) { correctorRow }
                }
                card("Shortcut and display") {
                    row("Dictation") { enabledRow }
                    row("Right ⌘") { rightCommandRow }
                    row("Hotkey") { hotkeyRow }
                    row("While you speak") { hudRow }
                    row("Output", last: true) { outputRow }
                }
                card("Models") {
                    row("Speech") { memoryRow }
                    row("Providers", last: true) { providersRow }
                }
                Text("Closing this window keeps Murmator in the menu bar.")
                    .font(.system(size: 12)).foregroundStyle(palette.note)
            }
            .padding(.init(top: 16, leading: 20, bottom: 18, trailing: 20))
        }
        .scrollIndicators(.automatic)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420)
        .background(palette.background)
        .navigationTitle("Murmator")
        .navigationSubtitle(status.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PrimaryDictationButton(action: PrimaryDictationAction.current(dictation), width: 156) {
                    if let onToggleDictation { onToggleDictation() } else { dictation.toggleFromMenu() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .toolbarBackground(palette.titleBar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onChange(of: translateToRaw) { showTranslationDetails = false }
        .onChange(of: languageRaw) {
            showTranslationDetails = false
            if !ControlsChoices.targets(dictating: languageRaw).contains(translateToRaw) {
                translateToRaw = TranslationSetting.off
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in screensGeneration += 1 }
        // The window stays open, so devices and the shortcut can change under it.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            shortcutClash = SystemShortcuts.clash(for: .dictate)
        }
        .onAppear {
            refreshMicrophones()
            shortcutClash = SystemShortcuts.clash(for: .dictate)
        }
    }

    private func refreshMicrophones() {
        _ = dictation.refreshMicrophones(preferredUID: microphoneUID)
    }

    // MARK: layout

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) -> some View {
        ControlsCard(title: title, content: content)
    }

    private func row<Content: View>(_ title: LocalizedStringKey, last: Bool = false,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        ControlsRow(title: title, last: last, content: content)
    }

    private func note(_ text: String, error: Bool = false) -> some View {
        ControlsNote(text: text, error: error)
    }

    private func link(_ title: LocalizedStringKey, _ perform: @escaping () -> Void) -> some View {
        ControlsLink(title: title, perform: perform)
    }

    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        ControlsSwitch(title: title, isOn: isOn)
    }

    // MARK: Dictation

    @ViewBuilder private var microphoneRow: some View {
        MurPopup(label: "Microphone", selection: MicrophoneChoice.binding($microphoneUID, devices: dictation.microphones),
                 options: [MicrophoneSetting.systemDefaultUID] + dictation.microphones.map(\.uid),
                 title: { uid in
                     uid == MicrophoneSetting.systemDefaultUID
                         ? String(localized: "System default")
                         : dictation.microphones.first { $0.uid == uid }?.name ?? uid
                 }, maxWidth: 260)
            .disabled(locked)
        if dictation.state != .recording {
            note(String(localized: "If it disconnects, System default is used until it returns."))
        }
    }

    @ViewBuilder private var modelRow: some View {
        MurSegment(label: "Model", selection: $modelRaw, options: ControlsChoices.modes(for: languageRaw))
            .frame(maxWidth: 300)
            .disabled(locked)
        note(ControlsChoices.modeNote(DictationMode(rawValue: modelRaw) ?? .hybrid))
        if !DictationMode.allowsLiveDraft(language: languageRaw) {
            note(String(localized: "The live draft is unreliable in this language, so only the accurate pass runs."))
        }
    }

    @ViewBuilder private var languageRow: some View {
        HStack(spacing: 8) {
            MurPopup(label: "Language", selection: $languageRaw,
                     options: ControlsChoices.languages(dictation, including: languageRaw),
                     title: SpeechLanguage.displayName(for:))
                .disabled(locked)
            Text(verbatim: "→").font(.system(size: 12)).foregroundStyle(palette.faint).accessibilityHidden(true)
            // Disabled on this side only: Language is what makes translation possible again.
            MurPopup(label: "Translate to", selection: $translateToRaw,
                     options: ControlsChoices.targets(dictating: languageRaw),
                     title: ControlsChoices.targetName)
                .disabled(dictation.isActive || languageRaw == SpeechLanguage.automatic)
        }
        .frame(maxWidth: 300)
        translationState
        qualitySection
    }

    /// The bar takes the note's slot, so the row does not grow while models arrive.
    @ViewBuilder private var translationState: some View {
        if let download = dictation.translationDownload {
            downloadProgress(download, label: String(localized: "translation model"))
        } else if let error = dictation.translationPreparationError {
            note(translationErrorText, error: true)
            HStack(spacing: 14) {
                link("Retry") { dictation.retryTranslationPreparation() }
                    .disabled(!dictation.canRetryTranslationPreparation)
                    .accessibilityIdentifier("retryTranslationPreparation")
                link(showTranslationDetails ? "Hide details" : "Details") { showTranslationDetails.toggle() }
            }
            if showTranslationDetails {
                Text(verbatim: error).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.note).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if dictation.isPreparingTranslation {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                note(String(localized: "Preparing translation…"))
            }
        } else if let translationNote {
            note(translationNote)
        }
    }

    private var translationErrorText: String {
        let source = SpeechLanguage.displayName(for: languageRaw)
        let target = TranslationSetting.target.map(SpeechLanguage.displayName(for:)) ?? ""
        return String(localized: "Couldn’t prepare \(target) from \(source). Dictation is typed untranslated for now.")
    }

    private var translationNote: String? {
        if languageRaw == SpeechLanguage.automatic {
            return String(localized: "Translation needs a chosen language: automatic detection doesn’t say which one it heard.")
        }
        guard let target = TranslationSetting.target else { return nil }
        switch LanguagePair.route(from: languageRaw, to: target) {
        case .pivot?: return String(localized: "Routed through English, which costs a second model and some accuracy.")
        case .direct?: return nil
        case nil: return String(localized: "No model for this pair — dictation is typed untranslated.")
        }
    }

    @ViewBuilder private var qualitySection: some View {
        if let pair = dictation.qualityCandidatePair, dictation.qualityModelIsOffered(for: pair) {
            if dictation.qualityModelIsInstalled(for: pair) {
                note(String(localized: "Quality model installed — typed text uses it automatically."))
            } else if let download = dictation.qualityDownload(for: pair) {
                downloadProgress(download, label: String(localized: "quality model"))
            } else {
                link("Download quality model (\(qualityModelSize(for: pair)))") {
                    dictation.downloadQualityModel(for: pair)
                    PostHogSDK.shared.capture("quality_model_download_started", properties: ["pair": pair.description])
                }
                if let error = dictation.qualityDownloadError(for: pair) { note(error, error: true) }
            }
        }
    }

    /// Determinate: the manifest pins every file's size, so the fraction is measured.
    private func downloadProgress(_ download: DictationController.TranslationDownload, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: download.fraction).progressViewStyle(.linear).tint(Mur.accent)
            note(String(localized: "Downloading \(label) \(Self.megabytes(download.receivedBytes)) of \(Self.megabytes(download.totalBytes)) MB"))
        }
    }

    private static func megabytes(_ bytes: Int64) -> String { String(format: "%.0f", Double(bytes) / 1_000_000) }

    private func qualityModelSize(for pair: LanguagePair) -> String {
        guard let bytes = TranslationDownloader.expectedDownloadBytes(for: pair, kind: .quality) else { return "" }
        return "~\(Self.megabytes(bytes)) MB"
    }

    @ViewBuilder private var correctorRow: some View {
        switchRow("Fix spelling and punctuation", isOn: $corrector)
            .disabled(dictation.isActive || captions)
        note(captions
            ? String(localized: "Not used for captions.")
            : String(localized: "Runs after you stop, in every dictation mode."))
    }

    // MARK: Shortcut and display

    private var enabledRow: some View {
        switchRow("Respond to the shortcuts", isOn: $enabled)
    }

    @ViewBuilder private var rightCommandRow: some View {
        switchRow("Tap to dictate at the caret", isOn: $rightCommand)
        note(String(localized: "Return inserts, Esc cancels. Hold to talk, release to insert."))
    }

    @ViewBuilder private var hotkeyRow: some View {
        HStack(spacing: 10) {
            MurSegment(label: "Hotkey", selection: $triggerRaw,
                       options: [(TriggerMode.hold.rawValue, String(localized: "Hold")),
                                 (TriggerMode.toggle.rawValue, String(localized: "Toggle"))], compact: true)
                .disabled(dictation.isActive)
            ShortcutChip { dictation.shortcutLabel }
        }
        if let shortcutClash, let chord = KeyboardShortcuts.getShortcut(for: .dictate)?.description {
            HStack(spacing: 10) {
                note(shortcutClash == .inputSource
                    ? String(localized: "\(chord) also switches your keyboard layout")
                    : String(localized: "macOS also uses \(chord)"), error: true)
                link("Change…") { onSettings() }
            }
        }
    }

    @ViewBuilder private var hudRow: some View {
        MurPopup(label: "While you speak", selection: $hudStyle, options: [.caret, .compact, .full],
                 title: { style in
                     switch style {
                     case .caret: String(localized: "At the caret")
                     case .compact: String(localized: "Compact")
                     case .full: String(localized: "Full")
                     }
                 }, maxWidth: 260)
    }

    @ViewBuilder private var outputRow: some View {
        MurSegment(label: "Output", selection: $appModeRaw,
                   options: [(AppMode.dictation.rawValue, String(localized: "Dictation")),
                             (AppMode.captions.rawValue, String(localized: "Captions"))], compact: true)
            .disabled(locked)
        if captions {
            note(String(localized: "Start above or tap the shortcut; the same again stops. Nothing is typed into other apps."))
            displayPicker
            link("Caption appearance & layout…") { showingCaptionsAppearance = true }
                .popover(isPresented: $showingCaptionsAppearance) {
                    CaptionsCustomizationView(overlay: dictation.captionsOverlay,
                                              display: captionsDisplay,
                                              translating: TranslationSetting.target != nil,
                                              preferences: dictation.captionsOverlay.preferences)
                }
        }
    }

    private var screenOptions: [(uuid: String, name: String)] {
        _ = screensGeneration
        return NSScreen.screens.compactMap { screen in CaptionsDisplay.uuid(of: screen).map { ($0, screen.localizedName) } }
    }

    /// Stays enabled mid-session: moving the overlay is safe during a talk.
    @ViewBuilder private var displayPicker: some View {
        let options = screenOptions
        let missing = captionsDisplay != CaptionsDisplay.followCursor && !options.contains { $0.uuid == captionsDisplay }
        MurPopup(label: "Show on", selection: $captionsDisplay,
                 options: [CaptionsDisplay.followCursor] + options.map(\.uuid) + (missing ? [captionsDisplay] : []),
                 title: { uuid in
                     if uuid == CaptionsDisplay.followCursor { return String(localized: "Screen with cursor") }
                     return options.first { $0.uuid == uuid }?.name ?? String(localized: "Saved display (not connected)")
                 }, maxWidth: 260)
        if missing {
            note(String(localized: "That display is not connected, so captions appear on the screen with the cursor."))
        }
    }

    // MARK: Models

    @ViewBuilder private var memoryRow: some View {
        if dictation.isManagingModels {
            ProgressView(value: dictation.modelPreparation?.fraction)
                .progressViewStyle(.linear).tint(Mur.accent)
                .accessibilityLabel(dictation.modelPreparationStatus)
            note(dictation.modelPreparationStatus)
        } else if let name = dictation.loadedModelName {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: String(localized: "In memory: \(name)")).font(.system(size: 13)).foregroundStyle(palette.ink)
                Spacer(minLength: 0)
                link("Unload") { dictation.releaseModels() }
                    .disabled(!dictation.canChangeModels)
                    .help("Unloads models from memory. Downloaded files stay on this Mac.")
            }
        } else {
            HStack(spacing: 10) {
                note(dictation.shortStatus)
                Spacer(minLength: 0)
                if case .error = dictation.state {
                    link("Unload") { dictation.releaseModels() }
                        .help("Unloads models from memory. Downloaded files stay on this Mac.")
                }
            }
        }
        note(String(localized: "Downloaded models stay on this Mac."))
    }

    @ViewBuilder private var providersRow: some View {
        HStack(spacing: 10) {
            note(String(localized: "Cloud providers and models for each step"))
            Spacer(minLength: 0)
            link("Settings…") {
                PostHogSDK.shared.capture("settings_opened")
                (onProviders ?? onSettings)()
            }
        }
    }
}
