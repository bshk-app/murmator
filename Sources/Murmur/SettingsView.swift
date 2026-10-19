import AppKit
import KeyboardShortcuts
import class MurmurCloud.ProviderPreferences
import enum AIProvidersCore.AIOperation
import MurmurKit
import SwiftUI

/// The Settings pages, in sidebar order. `rawValue` is the section that
/// `presentSettings(section:)` asks for.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, onScreen, models, providers, privacy, about

    static let requestKey = "murmator.settings.requestedSection"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .onScreen: "On-screen"
        case .models: "Models"
        case .providers: "Providers"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var lead: LocalizedStringKey {
        switch self {
        case .general: "How Murmator looks and when it gets ready."
        case .shortcuts: "Ways to start a dictation without the mouse."
        case .onScreen: "What you see while you speak."
        case .models: "Choose who runs each step: this Mac or one of your connections."
        case .providers: "Where cloud models come from. Each connection keeps its own key."
        case .privacy: "Nothing you say leaves this Mac unless you pick a cloud step."
        case .about: "On-device dictation and translation."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .onScreen: "text.bubble"
        case .models: "waveform"
        case .providers: "cloud"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// The sidebar's two groups, like System Settings: setup, then the rest.
    static let groups: [[SettingsTab]] = [[.general, .shortcuts, .onScreen, .models, .providers], [.privacy, .about]]

    /// The page a request names, or nil for anything unknown.
    init?(request: String?) {
        guard let request, let tab = Self(rawValue: request) else { return nil }
        self = tab
    }

    /// Takes the request left by `presentSettings(section:)`; read once, then cleared.
    static func takeRequest(_ defaults: UserDefaults = .standard) -> SettingsTab? {
        defer { defaults.removeObject(forKey: requestKey) }
        return SettingsTab(request: defaults.string(forKey: requestKey))
    }
}

/// Murmator's Settings window (design: Claude Design «Murmator Mac Settings
/// v1»): a sidebar of pages on the warm side surface, the page on the right.
/// Mode, language and corrector changes run their side effects through
/// `ControlSettingsObserver`; only the keys it does not watch prepare here.
struct SettingsView: View {
    let dictation: DictationController
    @State var tab: SettingsTab = .general
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        HStack(spacing: 0) {
            SettingsSidebar(tab: $tab)
                .frame(width: 214)
                .background(palette.titleBar)
                .overlay(alignment: .trailing) { Rectangle().fill(palette.hairline).frame(width: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tab.title).font(.system(size: 21, weight: .bold)).foregroundStyle(palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(tab.lead).font(.system(size: 12.5)).foregroundStyle(palette.note)
                    }
                    SettingsPage(tab: tab, dictation: dictation)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(tab)   // each page starts at the top
            .background(palette.background)
        }
        .frame(width: 780, height: 600)
        .tint(Mur.accent)
        .onAppear { if let requested = SettingsTab.takeRequest() { tab = requested } }
        .onReceive(NotificationCenter.default.publisher(for: .murmatorShowSettingsSection)) { event in
            if let requested = SettingsTab(request: event.object as? String) {
                tab = requested
                UserDefaults.standard.removeObject(forKey: SettingsTab.requestKey)
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var tab: SettingsTab
    @AppStorage(MascotStyle.defaultsKey) private var storedStyle = MascotStyle.defaultStyle.rawValue
    @AppStorage(MascotStyle.moustacheDefaultsKey) private var hasMoustache = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MascotPortrait(style: .resolve(storedStyle), hasMoustache: hasMoustache)
                    .frame(width: 26, height: 26)
                    .frame(width: 34, height: 34)
                    .background(Color(red: 36 / 255, green: 31 / 255, blue: 28 / 255),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Murmator").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                    Text("Settings").font(.system(size: 11.5)).foregroundStyle(palette.note)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
            ForEach(SettingsTab.groups.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    ForEach(SettingsTab.groups[index]) { item in SidebarItem(item: item, selection: $tab) }
                }
                .padding(.bottom, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct SidebarItem: View {
    let item: SettingsTab
    @Binding var selection: SettingsTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        let selected = selection == item
        let connections = item == .providers ? ProviderPreferences.shared.connections.count : 0
        Button { selection = item } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? MacPalette.onAccent : palette.accentText)
                    .frame(width: 22, height: 22)
                    .background(selected ? MacPalette.onAccent.opacity(0.14) : palette.keyCap,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? MacPalette.onAccent : palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if connections > 0 {
                    Text(verbatim: "\(connections)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? MacPalette.onAccent : palette.note)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(selected ? MacPalette.onAccent.opacity(0.16) : palette.keyCap, in: Capsule())
                        .accessibilityLabel("\(connections) connections")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selected ? Mur.accent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("settings-tab-\(item.rawValue)")
    }
}

/// The controls of one page. Every setting from the former single form lives
/// on exactly one page.
private struct SettingsPage: View {
    let tab: SettingsTab
    let dictation: DictationController
    @AppStorage(WhistleSetting.key) private var whistleFastEnabled = false
    @AppStorage(SpeechLanguage.defaultsKey) private var language = SpeechLanguage.current
    @AppStorage(ControlSettingsObserver.correctorKey) private var postProcessingEnabled = false
    @AppStorage("speechPostProcessingModel") private var postProcessingModel = "automatic"
    @AppStorage(ModelLoadingPolicy.key) private var modelLoadingPolicy = ModelLoadingPolicy.atLaunch.rawValue
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false
    @AppStorage(RightCommandTrigger.key) private var rightCommand = true
    @AppStorage(HUDStyle.defaultsKey) private var hudStyle: HUDStyle = .caret
    @AppStorage(DictationSession.recordUtterancesKey) private var recordUtterances = false
    @State private var confirmingDelete = false
    /// Counted when the page appears and after a delete, never inside `body`:
    /// touching the filesystem on every re-render would run it on each
    /// animation frame of the switch above it.
    @State private var recordingCount = 0
    /// Whether macOS answers to the same chords. Checked when the page shows,
    /// when a shortcut changes, and when Murmator comes back to the front.
    @State private var dictateClash: SystemShortcutClash?
    @State private var sendClash: SystemShortcutClash?
    @Environment(\.colorScheme) private var scheme

    private let labelWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch tab {
            case .general: general
            case .shortcuts: shortcuts
            case .onScreen: onScreen
            case .models: models
            case .providers: providers
            case .privacy: privacy
            case .about: about
            }
        }
        .onAppear {
            recordingCount = DiagnosticRecordings.count()
            refreshClashes()
        }
        // Back from System Settings, where the macOS shortcut may just have been turned off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClashes()
        }
    }

    // MARK: pages

    @ViewBuilder private var general: some View {
        ControlsCard(title: "Mascot") {
            ControlsRow(last: true) { MascotStylePicker() }
        }
        ControlsCard(title: "Model loading") {
            ControlsRow(title: "Load models", labelWidth: labelWidth, last: true) {
                MurSegment(label: "Load models", selection: $modelLoadingPolicy,
                           options: [(ModelLoadingPolicy.atLaunch.rawValue, String(localized: "When Murmator starts")),
                                     (ModelLoadingPolicy.onDemand.rawValue, String(localized: "When dictation starts"))],
                           compact: true)
                    .accessibilityIdentifier("model-loading-policy")
                    .disabled(!dictation.canChangeModels)
                    .onChange(of: modelLoadingPolicy) { _, _ in
                        dictation.prepareCurrentMode()
                        dictation.prepareTranslation()
                    }
                ControlsNote(text: String(localized: "At launch prepares speech and the enabled corrector in advance and keeps them in memory. On demand prepares them when needed; Murmator shows progress while preparing."))
            }
        }
    }

    @ViewBuilder private var shortcuts: some View {
        ControlsCard(title: "Right ⌘") {
            ControlsRow(last: true) {
                ControlsSwitch(title: "Dictate with right ⌘", isOn: $rightCommand)
                ControlsNote(text: String(localized: "Tap right ⌘ and speak, then press Return to insert the text or Esc to throw it away. Press Return twice to insert and send. Or hold right ⌘ while you speak and let go to insert. Needs Accessibility, like typing does."))
            }
        }
        ControlsCard(title: "Keyboard shortcuts",
                     footer: String(localized: "Hold a shortcut to dictate; release to finish. “Dictate and send” also presses Return, which sends the message in most chats. Leave it empty if you mostly dictate into editors, where Return would just break the line.")) {
            ControlsRow(title: "Push-to-talk", labelWidth: labelWidth) {
                KeyboardShortcuts.Recorder(for: .dictate) { _ in refreshClashes() }
                    .accessibilityLabel("Push-to-talk")
                clashNote(dictateClash, name: .dictate)
            }
            ControlsRow(title: "Dictate and send", labelWidth: labelWidth, last: true) {
                KeyboardShortcuts.Recorder(for: .dictateAndSend) { _ in refreshClashes() }
                    .accessibilityLabel("Dictate and send")
                clashNote(sendClash, name: .dictateAndSend)
            }
        }
    }

    @ViewBuilder private var onScreen: some View {
        ControlsCard(title: "While you speak") {
            ControlsRow(title: "Show", labelWidth: labelWidth, last: true) {
                MurSegment(label: "While you speak", selection: Binding(get: { hudStyle.rawValue },
                                                                       set: { hudStyle = HUDStyle(rawValue: $0) ?? .caret }),
                           options: [(HUDStyle.caret.rawValue, String(localized: "At the caret")),
                                     (HUDStyle.compact.rawValue, String(localized: "Compact")),
                                     (HUDStyle.full.rawValue, String(localized: "Full"))],
                           compact: true)
                ControlsNote(text: String(localized: "At the caret draws your words where they will be inserted, as they are recognised; nothing is typed until you finish. When the caret is unavailable, your words appear above the compact capsule. Compact shows only the recording status. Full shows your words in a larger pill at the bottom of the screen."))
            }
        }
    }

    /// Each step: the provider first, then its model. Local shows the models
    /// this Mac runs and their settings, on the keys they always used.
    @ViewBuilder private var models: some View {
        ControlsCard(title: "Live recognition") {
            ControlsRow(last: true) {
                picker(.streamingTranscription) {
                    localModel("Nemotron on this Mac", note: "Fast and Hybrid. Some languages skip the live draft.")
                    LabeledContent("English Fast") {
                        Picker("English Fast model", selection: $whistleFastEnabled) {
                            Text("Nemotron (GPU)").tag(false)
                            Text("Whistle (CPU)").tag(true)
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("englishFastModelPicker")
                        .onChange(of: whistleFastEnabled) { _, _ in dictation.prepareCurrentMode() }
                    }
                    ControlsNote(text: String(localized: "Whistle runs on this Mac and downloads a 17 MB model on first use. Choose English and Fast in the menu to use it."))
                }
            }
        }
        ControlsCard(title: "Accurate recognition") {
            ControlsRow(last: true) {
                picker(.transcription) {
                    LabeledContent("Model") { Text("Automatic for the spoken language") }
                    ControlsNote(text: accurateLocalNote)
                }
            }
        }
        ControlsCard(title: "Corrector",
                     footer: String(localized: "Whisper detects the spoken language after recording. The chosen model then corrects the final text. Local models download on first use; cloud models need a connection in Providers.")) {
            ControlsRow {
                ControlsSwitch(title: "Post-process after recording", isOn: $postProcessingEnabled)
                    .accessibilityIdentifier("speech-post-processing-toggle")
                    .disabled(!dictation.canChangeModels)
            }
            // Shown whether or not the corrector is on, so the model can be chosen first.
            ControlsRow(last: true) {
                picker(.textEditing) {
                    LabeledContent("Model") {
                        Picker("Local model", selection: $postProcessingModel) {
                            Text("Automatic for detected language").tag("automatic")
                            ForEach(LocalTextModel.availableCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("text-editing-model-picker")
                        .onChange(of: postProcessingModel) { _, _ in dictation.prepareCurrentMode() }
                    }
                }
            }
        }
        ControlsCard(title: "Translation") {
            ControlsRow(last: true) {
                picker(.translation) {
                    localModel("On this Mac", note: "Language packs download on first use.")
                }
            }
        }
    }

    private func picker<Local: View>(_ operation: AIOperation, @ViewBuilder local: @escaping () -> Local) -> some View {
        ProviderModelPicker(operation: operation, title: operation.settingsTitle, onChange: prepare, local: local)
            .disabled(!dictation.canChangeModels)
    }

    @ViewBuilder private func localModel(_ name: LocalizedStringKey, note: String.LocalizationValue) -> some View {
        LabeledContent("Model") { Text(name) }
        ControlsNote(text: String(localized: note))
    }

    /// The on-device model the accurate pass uses for the language set now
    /// (GigaAM for Russian, Parakeet or Whisper elsewhere); nothing is saved here.
    private var accurateLocalNote: String {
        let model = SpeechRecognitionProfile.baselineModel(language: language).title
        let spoken = language == SpeechLanguage.automatic ? String(localized: "the detected language")
            : SpeechLanguage.displayName(for: language)
        return String(localized: "Hybrid and Accurate. Now \(model) for \(spoken).")
    }

    private func prepare() {
        dictation.prepareCurrentMode()
        dictation.prepareTranslation()
    }

    @ViewBuilder private var providers: some View {
        ControlsCard(title: "Connections") {
            ControlsRow(last: true) {
                ProviderConnectionsSettingsView(onChange: prepare)
                    .disabled(!dictation.canChangeModels)
            }
        }
    }

    @ViewBuilder private var privacy: some View {
        ControlsCard(title: "Usage") {
            ControlsRow(last: true) {
                ControlsSwitch(title: "Share anonymous usage & crash reports", isOn: $analyticsEnabled)
                    .onChange(of: analyticsEnabled) { _, on in AnalyticsConsent.set(on) }
                ControlsNote(text: String(localized: "Helps fix bugs and improve Murmator. Only anonymous events and errors are sent — never your audio or transcripts. Analytics does not change the processing providers you select."))
            }
        }
        ControlsCard(title: "Diagnostics",
                     footer: String(localized: "Saves your dictated audio as WAV files on this Mac so a bug can be reproduced from the real recording. Off by default. Nothing is uploaded. The last \(DiagnosticRecordings.keepNewest) recordings are kept for \(Int(DiagnosticRecordings.maxAge / 86_400)) days, then deleted automatically.")) {
            // Turning it off only stops new recordings. Deleting is a separate,
            // confirmed action: a switch must not destroy someone's audio as a
            // side effect of being flipped.
            ControlsRow {
                ControlsSwitch(title: "Keep recordings of what I dictate", isOn: $recordUtterances)
            }
            ControlsRow(last: true) {
                HStack(spacing: 8) {
                    Button("Show Recordings") { NSWorkspace.shared.open(DiagnosticRecordings.directory()) }
                    Button("Delete Recordings Now…", role: .destructive) { confirmingDelete = true }
                        .disabled(recordingCount == 0)
                }
            }
        }
        .confirmationDialog(
            "Delete \(recordingCount) recording\(recordingCount == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                DiagnosticRecordings.deleteAll()
                recordingCount = DiagnosticRecordings.count()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved audio of what you dictated. It cannot be undone.")
        }
    }

    @ViewBuilder private var about: some View {
        ControlsCard(title: "Murmator") {
            ControlsRow(title: "Version", labelWidth: labelWidth) {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .textSelection(.enabled)
            }
            ControlsRow(title: "Build", labelWidth: labelWidth, last: true) {
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("settings-version")
    }

    // MARK: shortcut clashes

    private func refreshClashes() {
        dictateClash = SystemShortcuts.clash(for: .dictate)
        sendClash = SystemShortcuts.clash(for: .dictateAndSend)
    }

    @ViewBuilder
    private func clashNote(_ clash: SystemShortcutClash?, name: KeyboardShortcuts.Name) -> some View {
        if let clash, let chord = KeyboardShortcuts.getShortcut(for: name)?.description {
            VStack(alignment: .leading, spacing: 6) {
                ControlsNote(text: SystemShortcuts.warning(clash, chord: chord), error: true)
                ControlsLink(title: "Open Keyboard Settings…") { NSWorkspace.shared.open(SystemShortcuts.settingsURL) }
            }
        }
    }
}
