import AppKit
@preconcurrency import AVFoundation
import KeyboardShortcuts
import MurmurKit
import PostHog
import SwiftUI
import class MurmurCloud.ProviderPreferences

// Building blocks shared by the menu bar panel (`MenuPopover`) and the
// Murmator window (`MainControlView`). Design: Claude Design «Murmator Mac
// Controls v4», which takes its look from MurMur.dc.html (menu bar dropdown)
// and Murmator Mac Advisor and Window.dc.html.

/// The Mac palette of those mocks: warm cream and warm near-black surfaces,
/// warm-brown neutrals, one orange accent with near-black ink on it.
struct MacPalette {
    let dark: Bool

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ o: Double = 1) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255, opacity: o)
    }

    /// Ink on the accent fill: near-black, never white.
    static let onAccent = rgb(36, 31, 28)
    /// The Stop dictation fill; white text on it is 4.6:1.
    static let stop = Mur.error

    var panel: Color { dark ? Self.rgb(36, 31, 28, 0.96) : Self.rgb(250, 248, 244, 0.97) }
    var background: Color { dark ? Self.rgb(21, 17, 14) : Self.rgb(250, 247, 242) }
    var titleBar: Color { dark ? Self.rgb(26, 21, 18) : Self.rgb(242, 235, 225) }
    var card: Color { dark ? Self.rgb(30, 25, 22) : Self.rgb(255, 253, 249) }
    var line: Color { dark ? Self.rgb(250, 244, 236, 0.11) : Self.rgb(60, 40, 20, 0.11) }
    var hairline: Color { dark ? .white.opacity(0.07) : Self.rgb(60, 40, 20, 0.07) }
    var ink: Color { dark ? .white.opacity(0.95) : Self.rgb(42, 37, 32) }
    /// Labels above and beside controls; 4.5:1 or better in both schemes.
    var label: Color { dark ? .white.opacity(0.58) : Self.rgb(74, 62, 52, 0.76) }
    var note: Color { dark ? .white.opacity(0.68) : Self.rgb(74, 62, 52, 0.78) }
    var faint: Color { dark ? .white.opacity(0.5) : Self.rgb(74, 62, 52, 0.6) }
    var field: Color { dark ? .white.opacity(0.09) : Self.rgb(60, 40, 20, 0.05) }
    var fieldLine: Color { dark ? .white.opacity(0.12) : Self.rgb(60, 40, 20, 0.1) }
    var segmentTrack: Color { dark ? .white.opacity(0.07) : Self.rgb(60, 40, 20, 0.06) }
    var segmentText: Color { dark ? .white.opacity(0.66) : Self.rgb(74, 62, 52, 0.82) }
    var keyCap: Color { dark ? .white.opacity(0.1) : Self.rgb(60, 40, 20, 0.08) }
    var keyCapInk: Color { dark ? .white.opacity(0.85) : Self.rgb(74, 62, 52, 0.75) }
    /// Accent-coloured text; the accent itself is too light on cream.
    var accentText: Color { dark ? Self.rgb(240, 164, 105) : Self.rgb(169, 88, 26) }
    var errorText: Color { dark ? Self.rgb(232, 138, 122) : Self.rgb(181, 65, 47) }
    var errorTint: Color { dark ? Self.rgb(232, 138, 122, 0.12) : Self.rgb(181, 65, 47, 0.10) }
    var accentTint: Color { Mur.accent.opacity(dark ? 0.14 : 0.12) }
}

extension OnTheme {
    /// Accent-coloured text for the tour and the companion card.
    var accentText: Color { MacPalette(dark ? .dark : .light).accentText }
}

// MARK: - State shared by both surfaces

/// What the panel, the window title and the menu bar icon say about the
/// dictation right now. "Listening" only once the microphone delivers audio.
struct ControlsStatus: Equatable {
    enum Tone { case ready, live, working, error, off }
    let text: String
    let tone: Tone

    @MainActor
    static func current(_ dictation: DictationController, detailed: Bool) -> ControlsStatus {
        let microphone = ControlsChoices.microphoneName(dictation)
        if !DictationEnabled.value, !dictation.isActive {
            return .init(text: String(localized: "Dictation is off"), tone: .off)
        }
        switch dictation.state {
        case .recording:
            return dictation.hasCapturedAudio
                ? .init(text: String(localized: "Listening · \(microphone)"), tone: .live)
                : .init(text: String(localized: "Starting microphone…"), tone: .working)
        case .idle, .transcribed:
            guard dictation.loadedModelName != nil else { return .init(text: dictation.shortStatus, tone: .off) }
            guard detailed else { return .init(text: String(localized: "Ready"), tone: .ready) }
            return .init(text: String(localized: "Ready · \(ControlsChoices.modeName(ModelSetting.current)) · \(microphone) · microphone closed"),
                         tone: .ready)
        case .error: return .init(text: dictation.shortStatus, tone: .error)
        case .loadingModels, .unloadingModels, .startingRecording, .transcribing:
            return .init(text: dictation.shortStatus, tone: .working)
        default: return .init(text: dictation.shortStatus, tone: .off)
        }
    }
}

/// The one primary action: Start / Stop / Cancel, with the same rules in the
/// panel, the window toolbar and the Dock menu.
struct PrimaryDictationAction: Equatable {
    enum Kind { case start, stop, cancel }
    let title: String
    let kind: Kind
    let disabled: Bool

    @MainActor
    static func current(_ dictation: DictationController) -> PrimaryDictationAction {
        let captions = AppMode.current == .captions
        if dictation.state == .unloadingModels {
            return .init(title: String(localized: "Freeing memory…"), kind: .cancel, disabled: true)
        }
        if dictation.isStartingRecording { return .init(title: String(localized: "Cancel start"), kind: .cancel, disabled: false) }
        if dictation.isManagingModels { return .init(title: String(localized: "Cancel loading"), kind: .cancel, disabled: false) }
        if dictation.state == .recording || dictation.state == .transcribing {
            return .init(title: captions ? String(localized: "Stop captions") : String(localized: "Stop dictation"),
                         kind: .stop, disabled: dictation.state == .transcribing)
        }
        return .init(title: captions ? String(localized: "Start captions") : String(localized: "Start dictation"),
                     kind: .start, disabled: !DictationEnabled.value || dictation.isActive)
    }
}

/// Option lists for the pickers, in one place for both surfaces.
enum ControlsChoices {
    @MainActor
    static func microphoneName(_ dictation: DictationController) -> String {
        let uid = UserDefaults.standard.string(forKey: MicrophoneSetting.defaultsKey) ?? MicrophoneSetting.systemDefaultUID
        if uid == MicrophoneSetting.systemDefaultUID { return String(localized: "System default") }
        return dictation.microphones.first { $0.uid == uid }?.name ?? String(localized: "System default")
    }

    static func modeName(_ mode: DictationMode) -> String {
        switch mode {
        case .fast: String(localized: "Fast")
        case .hybrid: String(localized: "Hybrid")
        case .accurate: String(localized: "Accurate")
        }
    }

    /// Only the modes that will actually run for this language.
    @MainActor static func modes(for language: String) -> [(value: String, label: String)] {
        (ProviderPreferences.shared.selection(.streamingTranscription) == nil ? DictationMode.available(for: language) : DictationMode.allCases).map { ($0.rawValue, modeName($0)) }
    }

    static func modeNote(_ mode: DictationMode) -> String {
        switch mode {
        case .fast: String(localized: "Text appears as you speak.")
        case .hybrid: String(localized: "A quick draft, refined phrase by phrase in the background.")
        case .accurate: String(localized: "Text appears after you stop; most accurate.")
        }
    }

    @MainActor
    static func languages(_ dictation: DictationController, including current: String) -> [String] {
        let codes = Set(dictation.supportedLanguageCodes + [SpeechLanguage.automatic, current])
        return codes.sorted {
            if $0 == SpeechLanguage.automatic { return true }
            if $1 == SpeechLanguage.automatic { return false }
            return SpeechLanguage.displayName(for: $0)
                .localizedCaseInsensitiveCompare(SpeechLanguage.displayName(for: $1)) == .orderedAscending
        }
    }

    /// Off first, then the verified targets for the spoken language.
    static func targets(dictating language: String) -> [String] {
        [TranslationSetting.off] + TranslationSetting.offered(dictating: language)
    }

    static func targetName(_ code: String) -> String {
        code == TranslationSetting.off ? String(localized: "Off") : SpeechLanguage.displayName(for: code)
    }
}

// MARK: - Side effects of a settings change

/// Runs the work a settings change needs exactly once, whichever surface made
/// it — the menu bar panel, the window, the Dock menu or Settings all write the
/// same `UserDefaults` keys. Owned by the app delegate once the menu app runs.
@MainActor
final class ControlSettingsObserver {
    private let dictation: DictationController
    private var snapshot: [String: String]
    private var token: NSObjectProtocol?

    /// Keys whose change prepares the current mode, then the translation.
    static let correctorKey = "speechPostProcessingEnabled"
    static let modeKeys = [ModelSetting.key, AppMode.defaultsKey, SpeechLanguage.defaultsKey, correctorKey]
    static let translationKeys = [TranslationSetting.key, SpeechLanguage.defaultsKey]
    static let displayKey = CaptionsDisplay.defaultsKey
    private static let watched = Array(Set(modeKeys + translationKeys + [displayKey]))

    init(dictation: DictationController) {
        self.dictation = dictation
        snapshot = Self.read()
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    private static func read() -> [String: String] {
        Dictionary(uniqueKeysWithValues: watched.map { ($0, UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "") })
    }

    func defaultsChanged() {
        let now = Self.read()
        let changed = Set(now.keys.filter { now[$0] != snapshot[$0] })
        let before = snapshot
        snapshot = now
        guard !changed.isEmpty else { return }
        if !changed.isDisjoint(with: Self.modeKeys) { dictation.prepareCurrentMode() }
        if !changed.isDisjoint(with: Self.translationKeys) { dictation.prepareTranslation() }
        if changed.contains(Self.displayKey) {
            let display = now[Self.displayKey] ?? CaptionsDisplay.followCursor
            dictation.captionsOverlay.moveToDisplay(display)
            PostHogSDK.shared.capture("captions_display_changed", properties: [
                "pinned": display != CaptionsDisplay.followCursor, "screens": NSScreen.screens.count,
            ])
        }
        if changed.contains(ModelSetting.key) {
            PostHogSDK.shared.capture("model_mode_changed", properties: [
                "from_mode": before[ModelSetting.key] ?? "", "to_mode": now[ModelSetting.key] ?? "",
            ])
        }
        if changed.contains(AppMode.defaultsKey) {
            PostHogSDK.shared.capture("app_mode_changed", properties: [
                "from_mode": before[AppMode.defaultsKey] ?? "", "to_mode": now[AppMode.defaultsKey] ?? "",
            ])
        }
    }
}

extension Notification.Name {
    /// Ask Settings to show a section; `object` is the section id (`"providers"`).
    static let murmatorShowSettingsSection = Notification.Name("MurmatorShowSettingsSection")
}

// MARK: - Controls

/// Small caption above a control in the panel.
struct FieldLabel: View {
    let title: LocalizedStringKey
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(title).font(.system(size: 12)).foregroundStyle(MacPalette(scheme).label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pill segmented control: the selected segment is filled with the accent.
struct MurSegment: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let options: [(value: String, label: String)]
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = MacPalette(scheme)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button { selection = option.value } label: {
                    Text(verbatim: option.label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? MacPalette.onAccent : palette.segmentText)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .padding(.horizontal, compact ? 12 : 0)
                        .padding(.vertical, 7)
                        .background(selected ? Mur.accent : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(palette.segmentTrack, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize(horizontal: compact, vertical: false)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A pop-up button drawn as the mocks' field. The menu itself is the native one.
struct MurPopup<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var maxWidth: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let palette = MacPalette(scheme)
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { Text(verbatim: title($0)).tag($0) }
            } label: { Text(label) }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 9) {
                Text(verbatim: title(selection))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(palette.note)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: maxWidth ?? .infinity)
            .background(palette.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.fieldLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: maxWidth != nil, vertical: true)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}

/// Start / Stop / Cancel with a fixed height, so label changes never move
/// anything else.
struct PrimaryDictationButton: View {
    let action: PrimaryDictationAction
    var width: CGFloat? = nil
    let perform: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        Button(action: perform) {
            HStack(spacing: 7) {
                if action.kind == .stop {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Text(verbatim: action.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(action.kind == .start ? MacPalette.onAccent : action.kind == .stop ? .white : palette.ink)
            .frame(width: width, height: 32)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(fill(palette), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if action.kind == .cancel {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.fieldLine, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.disabled)
        .opacity(action.disabled ? 0.4 : 1)
        .accessibilityIdentifier("controls-start-stop")
    }

    private func fill(_ palette: MacPalette) -> AnyShapeStyle {
        switch action.kind {
        case .start: AnyShapeStyle(Mur.accent)
        case .stop: AnyShapeStyle(MacPalette.stop)
        case .cancel: AnyShapeStyle(palette.field)
        }
    }
}

/// The status dot: accent when ready, red while listening; it pulses only
/// while something is happening, and never under Reduce Motion.
struct StatusDot: View {
    let tone: ControlsStatus.Tone
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let palette = MacPalette(scheme)
        let color: Color = switch tone {
        case .ready, .working: Mur.accent
        case .live: MacPalette.stop
        case .error: palette.errorText
        case .off: palette.faint
        }
        let pulses = (tone == .live || tone == .working) && !reduceMotion
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(pulses && dim ? 0.4 : 1)
            .animation(pulses ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true) : nil, value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}

/// Live input bars: shown only while the microphone is open.
struct InputLevelBars: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        let palette = MacPalette(scheme)
        HStack(spacing: 3) {
            ForEach(0 ..< 8, id: \.self) { i in
                let lit = i < 5
                Capsule().fill(lit ? Mur.accent : palette.field)
                    .frame(width: 3, height: 18)
                    .scaleEffect(y: (up || reduceMotion) && lit ? 1 : 0.35, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.07), value: up)
            }
        }
        .frame(height: 18)
        .onAppear { up = true }
        .accessibilityHidden(true)
    }
}

/// An inline banner for a missing permission or a blocking error.
struct ControlsBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    let isError: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        HStack(alignment: .top, spacing: 9) {
            Text(verbatim: "!")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isError ? .white : MacPalette.onAccent)
                .frame(width: 18, height: 18)
                .background(isError ? palette.errorText : Mur.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(palette.ink)
                Text(verbatim: message).font(.system(size: 12)).foregroundStyle(palette.note)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(verbatim: actionTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accentText)
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(isError ? palette.errorTint : palette.accentTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.fieldLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Which banner, if any, both surfaces show above their settings.
struct ControlsAlert: Equatable {
    enum Kind { case microphone, accessibility }
    let kind: Kind

    var title: String {
        switch kind {
        case .microphone: String(localized: "Microphone access is off")
        case .accessibility: String(localized: "Allow Accessibility to type")
        }
    }
    var message: String {
        switch kind {
        case .microphone: String(localized: "Murmator can’t hear you until you allow it.")
        case .accessibility: String(localized: "Without it, the text is copied for you to paste.")
        }
    }
    var actionTitle: String {
        switch kind {
        case .microphone: String(localized: "Open System Settings…")
        case .accessibility: String(localized: "Allow…")
        }
    }
    var isError: Bool { kind == .microphone }

    @MainActor
    static func current(_ dictation: DictationController) -> ControlsAlert? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return .init(kind: .microphone)
        default: break
        }
        return dictation.needsAccessibilityToType ? .init(kind: .accessibility) : nil
    }

    @MainActor
    func perform(_ dictation: DictationController) {
        switch kind {
        case .microphone:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            dictation.requestAccessibility()
        }
    }
}

// MARK: - Menu bar icon

/// The status item: the mascot in colour (as in MurMur.dc.html), dimmed when
/// dictation is off, with accent bars while listening and a red dot on error.
enum StatusIconRenderer {
    enum State: Hashable { case idle, off, listening, working, error }

    @MainActor
    static func state(_ dictation: DictationController) -> State {
        if case .error = dictation.state { return .error }
        if dictation.state == .recording { return .listening }
        if dictation.isManagingModels || dictation.isStartingRecording || dictation.state == .transcribing { return .working }
        return DictationEnabled.value ? .idle : .off
    }

    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ state: State, artwork: String) -> NSImage {
        let key = "\(artwork)-\(state)"
        if let cached = cache[key] { return cached }
        let mascot = face(artwork: artwork) ?? NSImage(systemSymbolName: "cat.fill", accessibilityDescription: nil) ?? NSImage()
        let bars = state == .listening || state == .working
        let size = NSSize(width: bars ? 26 : 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let scale = min(18 / mascot.size.width, 18 / mascot.size.height)
            let faceSize = NSSize(width: mascot.size.width * scale, height: mascot.size.height * scale)
            mascot.draw(in: NSRect(x: (18 - faceSize.width) / 2, y: (18 - faceSize.height) / 2, width: faceSize.width, height: faceSize.height), from: .zero,
                        operation: .sourceOver, fraction: state == .off ? 0.45 : 1)
            let accent = NSColor(red: 0xE8 / 255, green: 0x89 / 255, blue: 0x3B / 255, alpha: 1)
            if bars {
                accent.setFill()
                let heights: [CGFloat] = state == .listening ? [6, 11, 8] : [4, 4, 4]
                for (i, height) in heights.enumerated() {
                    NSBezierPath(roundedRect: NSRect(x: 18.5 + Double(i) * 2.8, y: 3.5, width: 2, height: height),
                                 xRadius: 1, yRadius: 1).fill()
                }
            }
            if state == .error {
                NSColor(red: 0xC9 / 255, green: 0x4A / 255, blue: 0x3B / 255, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 11, y: 0.5, width: 7, height: 7)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Murmator"
        cache[key] = image
        return image
    }

    /// One neutral head, not the entire animation atlas. Costume/headgear and
    /// moustache come from the same asset selected by the mascot preference.
    @MainActor
    static func face(artwork: String) -> NSImage? {
        let base = artwork.replacingOccurrences(of: "_no_moustache", with: "")
        let selectedSheet = NSImage(named: artwork)
        guard let sheet = selectedSheet ?? NSImage(named: base),
              let pixels = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let classic = base == "mascot_classic" && (artwork == base || selectedSheet == nil)
        let frame = NSSize(width: CGFloat(pixels.width) / (classic ? 8 : 3), height: CGFloat(pixels.height) / (classic ? 11 : 2))
        let bounds: CGRect
        switch base {
        case "mascot_astronaut": bounds = CGRect(x: 0.11, y: 0.025, width: 0.80, height: 0.61)
        case "mascot_wizard": bounds = CGRect(x: 0.19, y: 0.015, width: 0.73, height: 0.65)
        case "mascot_classic" where classic: bounds = CGRect(x: 0.10, y: 0.015, width: 0.80, height: 0.71)
        default: bounds = CGRect(x: 0.12, y: 0.025, width: 0.80, height: 0.61)
        }
        let rect = CGRect(x: frame.width * bounds.minX, y: frame.height * bounds.minY,
                          width: frame.width * bounds.width, height: frame.height * bounds.height).integral
        guard let head = pixels.cropping(to: rect) else { return nil }
        return NSImage(cgImage: head, size: NSSize(width: head.width, height: head.height))
    }
}

/// Start and Stop in Murmator's own window: the text goes to the app that was
/// in front before, so that app must be frontmost again first. Cancelling a
/// start or a model load inserts nothing; with Murmator in the background the
/// right app is already in front.
enum ControlsFocus {
    static func returnsFocus(appIsActive: Bool, starting: Bool, managingModels: Bool) -> Bool {
        appIsActive && !starting && !managingModels
    }

    /// The toggle waits for the other app to come forward; it still runs only
    /// if nothing (a shortcut, a second click) changed the session meanwhile.
    static func stillWanted(wasActive: Bool, isActive: Bool, starting: Bool) -> Bool {
        isActive == wasActive && !starting
    }
}

enum AppPresence {
    /// Titled windows people work in; HUDs, panels and the menu bar panel don't keep a Dock icon.
    static func counts(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    static func needsDock(_ windows: [NSWindow]) -> Bool {
        windows.contains { counts($0) && $0.isVisible }
    }
}

/// The microphone to show: the saved one while it is connected, otherwise
/// System default. The saved choice itself is kept, so it comes back with the device.
enum MicrophoneChoice {
    static func shown(_ storedUID: String, devices: [MicrophoneDevice]) -> String {
        AudioInputDevices.sanitizedUID(storedUID, devices: devices)
    }

    static func binding(_ stored: Binding<String>, devices: [MicrophoneDevice]) -> Binding<String> {
        Binding(get: { shown(stored.wrappedValue, devices: devices) }, set: { stored.wrappedValue = $0 })
    }
}

/// The dictation shortcut as a key cap. It reads the shortcut's own defaults
/// key, so a change in Settings shows here at once.
struct ShortcutChip: View {
    var bordered = false
    let label: () -> String
    @AppStorage("KeyboardShortcuts_" + KeyboardShortcuts.Name.dictate.rawValue) private var stored: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = MacPalette(scheme)
        let _ = stored
        Text(verbatim: label())
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.keyCapInk)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(palette.keyCap, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.fieldLine, lineWidth: 1)
                }
            }
            .lineLimit(1)
    }
}
