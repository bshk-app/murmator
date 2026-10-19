import AppKit
import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Processing is local unless a cloud stage is selected.
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The onboarding and Murmator windows are AppKit `NSWindow`s owned by the
        // AppDelegate (a SwiftUI `Window` scene hides on deactivation and can't
        // open reliably at launch here). The live dictation backend stays deferred
        // until onboarding finishes (AppDelegate router) even though the icon is
        // always present.
        MenuBarExtra {
            MenuPopover(dictation: appDelegate.dictation,
                        onOpenWindow: { appDelegate.presentMainWindow() },
                        onSettings: { appDelegate.presentSettings() },
                        onToggleDictation: { appDelegate.toggleDictationFromControls() })
                .onAppear { appDelegate.rememberFrontmostApp() }
        } label: {
            MurmatorStatusIcon(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(dictation: appDelegate.dictation)
        }
        .commands {
            CommandMenu("Dictation") {
                Button("Copy Last Dictation") { appDelegate.dictation.copyLastDictation() }
                    .disabled(appDelegate.dictation.lastOutputText.isEmpty)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.checkForUpdates() }
            }
            CommandGroup(replacing: .help) {
                Button("Murmator Tour") { appDelegate.replayOnboarding() }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Murmator Window") { appDelegate.presentMainWindow() }
                    .keyboardShortcut("0")
            }
        }
    }
}

/// The status item (design: MurMur.dc.html — the mascot in colour with the
/// dictation state). Also captures the Settings action from the persistent
/// scene, so AppKit-hosted windows can open the same SwiftUI Settings window.
private struct MurmatorStatusIcon: View {
    let appDelegate: AppDelegate
    @Environment(\.openSettings) private var openSettings
    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(MascotStyle.defaultsKey) private var storedStyle = MascotStyle.defaultStyle.rawValue
    @AppStorage(MascotStyle.moustacheDefaultsKey) private var hasMoustache = true

    var body: some View {
        _ = enabled   // re-render when dictation is switched off
        let artwork = MascotStyle.resolve(storedStyle).artworkName(hasMoustache: hasMoustache)
        return Image(nsImage: StatusIconRenderer.image(StatusIconRenderer.state(appDelegate.dictation), artwork: artwork))
            .accessibilityLabel("Murmator")
            .onAppear { appDelegate.openSettingsAction = { openSettings() } }
    }
}
