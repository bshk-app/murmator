import AppKit
import KeyboardShortcuts
import MurmurKit
import PostHog
import SwiftUI

/// The menu-bar dropdown (design: MurMur.dc.html) shown as a `.window`-style
/// MenuBarExtra: mascot + master toggle, live status + hotkey, Start/Stop, a mic meter, the
/// Model / Insert / Hotkey segmented controls, and a Settings/Quit footer.
struct MenuPopover: View {
    let dictation: DictationController
    /// Re-open the onboarding window (resets to Welcome + presents it).
    let onSetupTour: () -> Void
    /// Ask Sparkle to check for app updates (AppDelegate brackets the activation policy).
    let onCheckForUpdates: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(AppMode.defaultsKey) private var appModeRaw = AppMode.dictation.rawValue
    @AppStorage(TriggerMode.defaultsKey) private var triggerRaw = TriggerMode.hold.rawValue
    @AppStorage(ModelSetting.key) private var modelRaw = DictationMode.hybrid.rawValue
    @AppStorage(SpeechLanguage.defaultsKey) private var languageRaw = SpeechLanguage.systemDefault
    @AppStorage(TranslationSetting.key) private var translateToRaw = TranslationSetting.off
    @AppStorage(MicrophoneSetting.defaultsKey)
    private var microphoneUID = MicrophoneSetting.systemDefaultUID
    @AppStorage(CaptionsDisplay.defaultsKey) private var captionsDisplay = CaptionsDisplay.followCursor
    /// Bumped on screen reconfiguration so the picker lists what is plugged in now.
    @State private var screensGeneration = 0
    @State private var showingCaptionsAppearance = false
    /// macOS answers to the push-to-talk chord too. Checked each time the menu
    /// opens: the user may have changed either side since.
    @State private var shortcutClash: SystemShortcutClash?

    var body: some View {
        VStack(spacing: 0) {
            head
            divider
            micRow
            divider
            settings
            divider
            footer
        }
        .frame(width: 300)
        .background(scheme == .dark
            ? Color(red: 36 / 255, green: 31 / 255, blue: 28 / 255)
            : Mur.cream)
        // Switching model loads the newly selected mode's models (lazy by mode).
        .onChange(of: modelRaw) { oldValue, newValue in
            dictation.prepareCurrentMode()
            PostHogSDK.shared.capture("model_mode_changed", properties: [
                "from_mode": oldValue,
                "to_mode": newValue,
            ])
        }
        // Captions needs the boundary detector on top of the dictation models, so
        // switching mode warms whatever the new one is missing.
        .onChange(of: appModeRaw) { oldValue, newValue in
            dictation.prepareCurrentMode()
            PostHogSDK.shared.capture("app_mode_changed", properties: [
                "from_mode": oldValue,
                "to_mode": newValue,
            ])
        }
        .onChange(of: captionsDisplay) { _, newValue in
            // A no-op unless a talk is on screen; the next one reads the setting at start.
            dictation.captionsOverlay.moveToDisplay(newValue)
            PostHogSDK.shared.capture("captions_display_changed", properties: [
                "pinned": newValue != CaptionsDisplay.followCursor,
                "screens": NSScreen.screens.count,
            ])
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in screensGeneration += 1 }
        .onAppear {
            let validUID = dictation.refreshMicrophones(preferredUID: microphoneUID)
            if validUID != microphoneUID { microphoneUID = validUID }
            shortcutClash = SystemShortcuts.clash(for: .dictate)
        }
    }

    // MARK: head

    private var head: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                MurmatorMascot(mood: dictation.mascotMood, size: 30)
                Text("Murmator").font(.system(size: 15, weight: .semibold)).foregroundStyle(primary)
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).tint(Mur.accent).labelsHidden()
            }
            HStack(spacing: 8) {
                Circle().fill(dictation.isActive ? Mur.accent : secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(dictation.shortStatus).font(.system(size: 12)).foregroundStyle(secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(dictation.triggerLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(fieldBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            if let shortcutClash, let chord = KeyboardShortcuts.getShortcut(for: .dictate)?.description {
                clashRow(shortcutClash, chord: chord)
            }
            startStopButton
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
    }

    /// The one place an existing user sees it: they set their chord long ago
    /// and do not open Settings, while macOS has been answering to it too.
    private func clashRow(_ clash: SystemShortcutClash, chord: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                .foregroundStyle(Mur.accent)
            Text(clash == .inputSource
                 ? String(localized: "\(chord) also switches your keyboard layout")
                 : String(localized: "macOS also uses \(chord)"))
                .font(.system(size: 11)).foregroundStyle(secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Change…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .buttonStyle(.link).font(.system(size: 11, weight: .semibold))
        }
    }
    private var isRecording: Bool { dictation.state == .recording }

    /// Stop is always offered; Start follows the master switch, like the hotkey.
    private var startStopDisabled: Bool {
        if dictation.state == .unloadingModels { return true }
        if isRecording || dictation.isManagingModels || dictation.isStartingRecording { return false }
        return !enabled || dictation.isActive
    }

    private var startStopTitle: String {
        if dictation.state == .unloadingModels { return String(localized: "Freeing memory…") }
        if dictation.isStartingRecording { return String(localized: "Cancel start") }
        if dictation.isManagingModels { return String(localized: "Cancel loading") }
        if dictation.state == .modelsUnloaded || (!dictation.isActive && dictation.loadedModelName == nil) {
            return String(localized: "Load models")
        }
        let what = appModeRaw == AppMode.captions.rawValue ? "captions" : "dictation"
        return isRecording ? "Stop \(what)" : "Start \(what)"
    }

    private var startStopButton: some View {
        return Button { dictation.toggleFromMenu() } label: {
            Text(startStopTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRecording ? primary : .white)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(isRecording ? fieldBG : Mur.accent,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(startStopDisabled)
        .opacity(startStopDisabled ? 0.45 : 1)
    }

    // MARK: mic meter (animated for now; live level is a later pass)

    private var micRow: some View {
        HStack(spacing: 11) {
            Text("Microphone").font(.system(size: 12)).foregroundStyle(secondary)
                .frame(width: 74, alignment: .leading)
            MeterBars(active: isRecording)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: segmented settings

    private var languageCodes: [String] {
        let codes = Set(dictation.supportedLanguageCodes + [SpeechLanguage.automatic, languageRaw])
        return codes.sorted {
            if $0 == SpeechLanguage.automatic { return true }
            if $1 == SpeechLanguage.automatic { return false }
            return SpeechLanguage.displayName(for: $0)
                .localizedCaseInsensitiveCompare(SpeechLanguage.displayName(for: $1)) == .orderedAscending
        }
    }

    /// Only the modes that will actually run: offering a choice that silently
    /// becomes another one is worse than not offering it.
    private var modelOptions: [(String, String)] {
        DictationMode.available(for: languageRaw).map { mode in
            switch mode {
            case .fast: return (mode.rawValue, "Fast")
            case .hybrid: return (mode.rawValue, "Hybrid")
            case .accurate: return (mode.rawValue, "Accurate")
            }
        }
    }

    /// Says the things a user cannot see for themselves: why the picker is
    /// disabled, that a pair routes through English, and that a pair has no
    /// model. Checked before the target so it also explains the disabled state.
    ///
    /// A determinate bar, because the size is genuinely known: the manifest
    /// pins every file's compressed length, so the fraction is measured bytes
    /// rather than an invented percentage.
    @ViewBuilder
    private func translationProgress(_ download: DictationController.TranslationDownload,
                                     label: String = "translation model") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: download.fraction)
                .progressViewStyle(.linear)
                .tint(Mur.accent)
            Text("Downloading \(label) \(Self.megabytes(download.receivedBytes)) of "
                 + "\(Self.megabytes(download.totalBytes)) MB")
                .font(.system(size: 11.5))
                .foregroundStyle(tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 7)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_000_000)
    }
    private var translationNote: String? {
        if languageRaw == SpeechLanguage.automatic {
            return "Translation needs an explicit language: neither recogniser reports "
                + "the one it heard, so there is nothing to translate from."
        }
        guard let target = TranslationSetting.target else { return nil }
        switch LanguagePair.route(from: languageRaw, to: target) {
        case .pivot?:
            return "Routed through English, which costs a second model and some accuracy."
        case .direct?:
            return nil
        case nil:
            return "No model for this pair \u{2014} dictation is pasted untranslated."
        }
    }

    /// The quality-model control: nothing for the 28/30 directions that have
    /// no CTranslate2 conversion yet, a download button for one that does but
    /// is not installed, a progress bar while it fetches, or a quiet
    /// confirmation once it has landed. Placed under the fast tier's own note
    /// so the two read as one "translation" section rather than two.
    @ViewBuilder
    private var qualitySection: some View {
        if let pair = dictation.qualityCandidatePair, dictation.qualityModelIsOffered(for: pair) {
            if dictation.qualityModelIsInstalled(for: pair) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Mur.accent)
                    Text("Quality model installed \u{2014} pasted text uses it automatically.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 7)
            } else if let download = dictation.qualityDownload(for: pair) {
                translationProgress(download, label: "quality model")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        dictation.downloadQualityModel(for: pair)
                        PostHogSDK.shared.capture("quality_model_download_started", properties: [
                            "pair": pair.description,
                        ])
                    } label: {
                        Text("Download quality model (\(qualityModelSize(for: pair)))")
                            .font(.system(size: 11.5)).foregroundStyle(Mur.accent)
                    }
                    .buttonStyle(.plain)
                    if let error = dictation.qualityDownloadError(for: pair) {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 7)
            }
        }
    }

    private func qualityModelSize(for pair: LanguagePair) -> String {
        guard let bytes = TranslationDownloader.expectedDownloadBytes(for: pair, kind: .quality)
        else { return "" }
        return "~\(Self.megabytes(bytes)) MB"
    }

    @ViewBuilder
    private var modelMemoryControls: some View {
        if dictation.isManagingModels {
            ProgressView(value: dictation.modelPreparation?.fraction)
                .progressViewStyle(.linear)
                .tint(Mur.accent)
                .accessibilityLabel(dictation.modelPreparationStatus)
                .padding(.top, 8)
        } else if let name = dictation.loadedModelName {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("In memory: \(name)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Unload") { dictation.releaseModels() }
                    .font(.system(size: 11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Mur.accent)
                    .disabled(!dictation.canChangeModels)
                    .help("Unloads models from memory. Downloaded files stay on this Mac.")
            }
            .padding(.top, 7)
        } else if case .error = dictation.state {
            Button("Unload") { dictation.releaseModels() }
                .font(.system(size: 11.5))
                .buttonStyle(.plain)
                .foregroundStyle(Mur.accent)
                .help("Unloads models from memory. Downloaded files stay on this Mac.")
                .padding(.top, 7)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Microphone")
            Picker("Microphone", selection: $microphoneUID) {
                Text("System Default").tag(MicrophoneSetting.systemDefaultUID)
                ForEach(dictation.microphones) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!dictation.canChangeModels)
            label("Mode").padding(.top, 11)
            MurSegment(label: "Mode", selection: $appModeRaw,
                       options: [(AppMode.dictation.rawValue, "Dictation"),
                                 (AppMode.captions.rawValue, "Captions")])
                // Switching pipelines under a live session is not a state worth
                // supporting — the running one owns the mic until it stops.
                .disabled(!dictation.canChangeModels)
            if appModeRaw == AppMode.captions.rawValue {
                Text("Start above or tap the shortcut; the same again stops. Nothing is typed into other apps.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                displayPicker
                Button("Caption appearance & layout…") { showingCaptionsAppearance = true }
                    .font(.system(size: 11.5)).padding(.top, 7)
                    .popover(isPresented: $showingCaptionsAppearance) {
                        CaptionsCustomizationView(overlay: dictation.captionsOverlay,
                                                  display: captionsDisplay,
                                                  translating: TranslationSetting.target != nil,
                                                  preferences: dictation.captionsOverlay.preferences)
                    }
            }
            label("Model").padding(.top, 11)
            MurSegment(label: "Model", selection: $modelRaw, options: modelOptions)
                .disabled(!dictation.canChangeModels)
            modelMemoryControls
            if !DictationMode.allowsLiveDraft(language: languageRaw) {
                Text("The live draft is unreliable in this language, so only the accurate pass runs.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            // Side by side with an arrow between, per MurMur.dc.html's
            // "language → translate to" row: the pair is one decision - what is
            // heard, and what comes out - and stacking them read as two
            // unrelated settings that happened to sit next to each other.
            HStack(alignment: .bottom, spacing: 9) {
                VStack(alignment: .leading, spacing: 0) {
                    label("Language")
                    Picker("Language", selection: $languageRaw) {
                        ForEach(languageCodes, id: \.self) { code in
                            Text(SpeechLanguage.displayName(for: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Changing this mid-utterance never reached the running
                    // recogniser anyway - it was already handed a language -
                    // so an enabled control was offering something it could
                    // not do. `DictationController.dictationSource` makes the
                    // stale choice harmless; this makes it un-offerable, and
                    // matches Translate to, which is disabled here too.
                    .disabled(!dictation.canChangeModels)
                }
                Text("\u{2192}")
                    .font(.system(size: 12))
                    .foregroundStyle(tertiary)
                    .padding(.bottom, 6)
                VStack(alignment: .leading, spacing: 0) {
                    label("Translate to")
                    Picker("Translate to", selection: $translateToRaw) {
                        Text("Off").tag(TranslationSetting.off)
                        ForEach(TranslationSetting.offered(dictating: languageRaw), id: \.self) { code in
                            Text(SpeechLanguage.displayName(for: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Automatic detection has no source language to route from, so the
                    // choice is unavailable rather than silently ineffective.
                    .disabled(dictation.isActive || languageRaw == SpeechLanguage.automatic)
                }
            }
            .padding(.top, 11)
            // `.disabled` lives on the Translate-to column above, not here: on
            // the row it would grey out the Language picker too, and Language
            // is exactly what you would reach for to make translation possible
            // again.
            // Fetch on choice, not on first use: 20 MB between the stop gesture
            // and the paste would stall the one moment that must feel instant.
            .onChange(of: translateToRaw) { dictation.prepareTranslation() }
            .onChange(of: languageRaw) { dictation.prepareTranslation() }
            // The bar takes the note's slot rather than adding a row, so the
            // popover does not grow and shrink while models arrive.
            if let download = dictation.translationDownload {
                translationProgress(download)
            } else if let note = translationNote {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }
            qualitySection
            label("Hotkey").padding(.top, 11)
            MurSegment(label: "Hotkey", selection: $triggerRaw,
                       options: [(TriggerMode.hold.rawValue, "Hold"),
                                 (TriggerMode.toggle.rawValue, "Toggle")])
                .disabled(dictation.isActive)
            if dictation.needsAccessibilityToType {
                Button { dictation.requestAccessibility() } label: {
                    Text("Grant Accessibility to type…")
                        .font(.system(size: 11.5)).foregroundStyle(Mur.accent)
                }
                .buttonStyle(.plain).padding(.top, 10)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(tertiary)
            .padding(.bottom, 7).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Screens as they are connected right now, keyed by the UUID that is saved.
    private var screenOptions: [(uuid: String, name: String)] {
        _ = screensGeneration
        return NSScreen.screens.compactMap { screen in
            CaptionsDisplay.uuid(of: screen).map { ($0, screen.localizedName) }
        }
    }

    /// Stays enabled mid-session: moving the overlay is safe, and a speaker who
    /// picked the laptop instead of the projector must not have to stop the talk.
    @ViewBuilder
    private var displayPicker: some View {
        let options = screenOptions
        let missing = captionsDisplay != CaptionsDisplay.followCursor
            && !options.contains { $0.uuid == captionsDisplay }
        label("Show on").padding(.top, 11)
        Picker("Show on", selection: $captionsDisplay) {
            Text("Screen with cursor").tag(CaptionsDisplay.followCursor)
            ForEach(options, id: \.uuid) { Text($0.name).tag($0.uuid) }
            // Keeps the saved choice selectable (and visible) while its
            // projector is unplugged, instead of silently showing a blank.
            if missing { Text("Saved display (not connected)").tag(captionsDisplay) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        if missing {
            Text("That display is not connected, so captions appear on the screen with the cursor.")
                .font(.system(size: 11.5))
                .foregroundStyle(tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
        }
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow("Settings…", "⌘ ,") {
                PostHogSDK.shared.capture("settings_opened")
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            footerRow("Check for Updates…", "") {
                PostHogSDK.shared.capture("check_for_updates")
                onCheckForUpdates()
            }
            // Re-run the first-run tour: reset to Welcome, then ask the App scene
            // (via the router) to open the onboarding window.
            footerRow("Setup tour…", "") { onSetupTour() }
            footerRow("Quit Murmator", "⌘ Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func footerRow(_ title: LocalizedStringKey, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(primary)
                Spacer()
                Text(verbatim: key).font(.system(size: 11, design: .monospaced)).foregroundStyle(tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: chrome

    private var divider: some View {
        Rectangle().fill(scheme == .dark ? Color.white.opacity(0.07) : Mur.ink.opacity(0.07)).frame(height: 1)
    }
    private var primary: Color { scheme == .dark ? Color.white.opacity(0.92) : Mur.ink }
    private var secondary: Color { scheme == .dark ? Color.white.opacity(0.6) : Mur.ink.opacity(0.65) }
    private var tertiary: Color { scheme == .dark ? Color.white.opacity(0.5) : Mur.ink.opacity(0.55) }
    private var fieldBG: Color { scheme == .dark ? Color.white.opacity(0.1) : Mur.ink.opacity(0.07) }
}

/// Pill segmented control matching the handoff (selected: white/accent fill).
private struct MurSegment: View {
    let label: String
    @Binding var selection: String
    let options: [(value: String, label: String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(textColor(selected: selected))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background { if selected { selectedPill } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityValue(selected ? "Selected" : "Not selected")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(scheme == .dark ? Color.white.opacity(0.07) : Mur.ink.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// The selected pill carries the fill, so its text takes the fill's contrast
    /// colour while the rest matches the popover's secondary text.
    private func textColor(selected: Bool) -> Color {
        let dark = scheme == .dark
        if selected {
            return dark ? Mur.ink : Mur.accent
        }
        return dark ? Color.white.opacity(0.6) : Mur.ink.opacity(0.65)
    }

    private var selectedPill: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(scheme == .dark ? Mur.accent : Color.white)
            .shadow(color: scheme == .dark ? .clear : Mur.ink.opacity(0.12), radius: 1, y: 1)
    }
}

/// Mic level meter — animated bars (live RMS is a later pass).
private struct MeterBars: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 8, id: \.self) { i in
                let lit = active && i < 5
                Capsule()
                    .fill(lit ? Mur.accent : (scheme == .dark ? Color.white.opacity(0.16) : Mur.ink.opacity(0.18)))
                    .frame(width: 3, height: 18)
                    .scaleEffect(y: (up || reduceMotion) && lit ? 1 : 0.4, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.07), value: up)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)   // decorative meter
        .onAppear { up = true }
    }
}
