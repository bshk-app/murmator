import AppKit
import SwiftUI

/// Murmur — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The onboarding window is an AppKit `NSWindow` owned by the AppDelegate
        // (a SwiftUI `Window` scene hides on deactivation and can't open reliably at
        // launch here). The live dictation backend stays deferred until onboarding
        // finishes (AppDelegate router) even though the icon is always present.
        MenuBarExtra {
            MenuPopover(dictation: appDelegate.dictation,
                        onSetupTour: { appDelegate.replayOnboarding() },
                        onCheckForUpdates: { appDelegate.checkForUpdates() })
        } label: {
            Image(nsImage: Self.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(dictation: appDelegate.dictation)
        }
    }

    /// A friendly template cat stays legible in both light and dark menu bars.
    private static let menuIcon: NSImage = {
        let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Murmator")
            ?? NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Murmator")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
