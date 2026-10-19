import AppKit
import MurmurKit
import PostHog
import SwiftUI

/// MurMur design tokens (from the Claude Design handoff: MurMur.dc.html).
enum Mur {
    static let accent = Color(red: 0xE8 / 255, green: 0x89 / 255, blue: 0x3B / 255)  // #E8893B
    static let ink    = Color(red: 0x2A / 255, green: 0x25 / 255, blue: 0x20 / 255)  // #2A2520
    static let error  = Color(red: 0xC9 / 255, green: 0x4A / 255, blue: 0x3B / 255)  // #C94A3B
    static let cream  = Color(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255)  // #FAF7F2

    /// Glass pill background per appearance (dark: warm near-black; light: warm cream).
    static func glass(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x1A / 255, green: 0x16 / 255, blue: 0x13 / 255).opacity(0.82)
            : Color(red: 0xFC / 255, green: 0xFA / 255, blue: 0xF6 / 255).opacity(0.85)
    }

    /// Crisp (finalized) transcript ink per appearance.
    static func crisp(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.97) : ink
    }

    /// Secondary text: present, but not competing with the transcript.
    ///
    /// `rgba(255,255,255,.66)` in MurMur.dc.html's "Live translation" block,
    /// where it paints a settled translation word. Deliberately not accent:
    /// accent already means something in this HUD - the newest confirmed word
    /// flashes in it - and with that flash sitting directly above the
    /// translation the two read as one block.
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.66) : ink.opacity(0.66)
    }

    /// The hairline between transcript and translation: `rgba(255,255,255,.1)`
    /// in the design's dark HUD, mirrored onto ink for the light theme.
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : ink.opacity(0.10)
    }

    static func draft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.34) : ink.opacity(0.34)
    }
}

/// What the app is doing right now.
///
/// Captions is not a variant of dictation. A speaker cannot hold a key through a
/// forty-minute talk, and nothing they say should be typed into whichever window
/// happens to be focused — so the trigger and the output both differ, and one
/// enum value each is cheaper than threading two exceptions everywhere.
enum AppMode: String, CaseIterable, Identifiable {
    case dictation
    case captions

    var id: String { rawValue }

    static let defaultsKey = "murmur.appMode"
    static var current: AppMode {
        AppMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .dictation
    }
}

/// Which screen the captions overlay lives on — persisted by display UUID.
///
/// Not an index into `NSScreen.screens` and not `NSScreenNumber`: both are
/// reassigned when a projector is unplugged and plugged back in. Only
/// `CGDisplayCreateUUIDFromDisplayID` survives that, which is exactly the
/// moment it matters — HDMI goes in minutes before the talk.
enum CaptionsDisplay {
    static let defaultsKey = "murmur.captionsDisplay"
    /// Stored as `""`: put the overlay wherever the cursor is.
    static let followCursor = ""

    static var current: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? followCursor
    }

    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The connected screen with this UUID, or nil when it is not plugged in
    /// (or `uuid` is `followCursor`).
    static func screen(for uuid: String) -> NSScreen? {
        guard uuid != followCursor else { return nil }
        return NSScreen.screens.first { Self.uuid(of: $0) == uuid }
    }

    /// The pinned screen when it is connected, otherwise the one under the
    /// cursor. A missing projector never stops the session — the text moves
    /// to a screen that exists.
    static func resolve(_ uuid: String) -> NSScreen? {
        screen(for: uuid) ?? .underCursor
    }
}

extension NSScreen {
    /// The screen under the cursor, then `.main`, then any. The cursor comes
    /// first because `.main` follows the key window, and this `.accessory`
    /// agent with non-activating panels never has one — on a multi-display
    /// setup it is not deterministic.
    static var underCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? .main ?? screens.first
    }
}

/// How the push-to-talk hotkey behaves.
enum TriggerMode: String, CaseIterable, Identifiable {
    case hold      // record while held, stop on release (push-to-talk)
    case toggle    // tap to start, tap again (or the HUD Stop button) to stop

    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to talk" : "Tap on / off" }

    static let defaultsKey = "murmur.triggerMode"
    static var current: TriggerMode {
        TriggerMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .hold
    }
}

/// How much the on-screen pill shows while you dictate, and where.
///
/// The words go where they will land by default. In a pill at the bottom of
/// the screen, a transcript growing and rewriting itself reads, in the corner
/// of your eye, as something jumping around; at the caret it reads as the
/// text being typed.
enum HUDStyle: String, CaseIterable, Identifiable {
    /// The draft drawn at the caret, in the field's type, until the corrected
    /// text is pasted over it (`GhostText`). Apps that do not say where their
    /// caret is get the compact controls with a separate live draft above them.
    case caret
    /// One small capsule that keeps its size and place for the whole
    /// utterance: level bars, then three dots while the text is finished.
    case compact
    /// The live two-tier transcript and the language badge.
    case full

    var id: String { rawValue }

    static let defaultsKey = "murmur.hudStyle"
    static var current: HUDStyle {
        HUDStyle(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .caret
    }
}
/// Tap right ⌘ to start dictating, Return to insert, Escape to throw it away.
///
/// On by default: a lone right ⌘ means nothing to macOS or to the apps people
/// dictate into, unlike a chord, which macOS may have a shortcut of its own
/// for (`SystemShortcuts`). Off is for people who have given right ⌘ a job of
/// their own (a layout switcher, Karabiner).
enum ModelLoadingPolicy: String, CaseIterable {
    case onDemand, atLaunch
    static let key = "murmur.modelLoadingPolicy"
    static var current: Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .atLaunch
    }
}

enum RightCommandTrigger {
    static let key = "murmur.rightCommandTap"
    /// Defaults to `true` when unset.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
    /// What the menu and the HUD call the key.
    static let label = "Right ⌘"
}

/// Language prompt for Nemotron's live draft. Parakeet final is multilingual.
enum SpeechLanguage {
    static let defaultsKey = "murmur.language"
    static let automatic = "auto"
    static let russian = "ru"
    static let english = "en"

    static var systemDefault: String {
        switch Locale.current.language.languageCode?.identifier {
        case "ru": return russian
        case "en": return english
        default: return automatic
        }
    }

    static var current: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? systemDefault
    }

    static func badge(for code: String) -> String {
        code == automatic ? "Auto" : code.uppercased()
    }

    static func displayName(for code: String) -> String {
        guard code != automatic else { return "Automatic" }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Master on/off — when off, the hotkey is ignored.
enum DictationEnabled {
    static let key = "murmur.enabled"
    /// Defaults to `true` when unset.
    static var value: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}

/// Which model(s) transcribe — persisted; read by DictationController at begin.
enum ModelSetting {
    static let key = "murmur.model"

    /// Falls back to Hybrid: Nemotron + Parakeet keep realtime on base chips.
    /// An explicit choice still wins.
    static var current: DictationMode {
        DictationMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .hybrid
    }
}

/// Target language for the two-line translate mode — persisted; read at stop.
///
/// Off by default and off is a real value, not a missing one: translation is a
/// second model and a second decision, and a dictation app that silently
/// started translating would be worse than one that never offered it.
///
/// Weights live beside the app's other downloads. The directory may not exist
/// yet — nothing downloads translation models at present — and that is a
/// tolerable state: `route` still resolves, loading then fails, and
/// `translateOrEmpty` falls back to pasting the original transcript.
enum TranslationModels {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/translation", isDirectory: true)
    }
}
enum TranslationSetting {
    static let key = "murmur.translateTo"
    static let off = "off"

    /// The language to translate into, or nil when the mode is off.
    static var target: String? {
        let value = UserDefaults.standard.string(forKey: key) ?? off
        return value == off ? nil : value
    }

    static var isOn: Bool { target != nil }

    /// Targets worth offering, minus whatever the user is dictating in: a
    /// source-to-itself choice is not a translation.
    static func offered(dictating source: String) -> [String] {
        LanguagePair.supportedLanguages
            .subtracting([source])
            .sorted()
    }

    /// Whether this pairing will actually produce something, without loading a
    /// model.
    ///
    /// Automatic detection cannot be translated, and that is a property of the
    /// recognisers rather than a gap here: neither reports the language it
    /// heard. Parakeet's `STTOutput.language` is the requested value echoed
    /// back, and Nemotron is prompted with a language rather than detecting one.
    /// With nothing to detect from there is no source to route from, so the
    /// mode requires an explicit language and the picker says so.
    static func canTranslate(from source: String) -> Bool {
        guard let target, source != SpeechLanguage.automatic else { return false }
        return LanguagePair.route(from: source, to: target) != nil
    }

    /// The target tag for the HUD's `RU → EN` badge, or `""` when this
    /// utterance will not be translated.
    ///
    /// Gated on `canTranslate` rather than on `target` alone: an unroutable
    /// pairing pastes the original transcript, so a badge promising `→ EN`
    /// there would be advertising something that never arrives.
    static func badge(dictating source: String) -> String {
        guard canTranslate(from: source), let target else { return "" }
        return target.uppercased()
    }
}

/// Anonymous usage & error analytics (PostHog). **Opt-in**: off until the user
/// enables it on the onboarding Welcome step (or in Settings). While off,
/// `PostHogSDK.shared.optOut()` makes every `capture(…)` a no-op — no audio or
/// transcripts are ever sent regardless.
enum AnalyticsConsent {
    static let key = "murmur.analyticsEnabled"
    /// Defaults to `false` (opt-in) when unset.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    /// SSOT for applying consent: persists + flips PostHog. Call from any toggle.
    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        on ? PostHogSDK.shared.optIn() : PostHogSDK.shared.optOut()
    }
}
