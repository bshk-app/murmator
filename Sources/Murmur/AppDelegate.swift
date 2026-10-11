import AppKit
import PostHog
import Sparkle
import SwiftUI

// PostHog project (ingestion) key — injected into Info.plist at `tuist generate` time from
// TUIST_MURMUR_POSTHOG_KEY (see Project.swift). Empty in plain source/fork builds, so analytics
// stays dark unless the maintainer's build supplies it. It's a write-only client key (not a
// secret); keeping it out of source just means forks don't phone home to our project.
private var posthogApiKey: String {
    Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String ?? ""
}
private let posthogHost = "https://eu.i.posthog.com"

/// Runs Murmur as a menu-bar agent, owns the dictation controller, and hosts the
/// onboarding window.
///
/// `.accessory` keeps the process alive in the background (so the global hotkey
/// keeps working) while staying out of the Dock and ⌘-Tab switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, SPUStandardUserDriverDelegate {
    let dictation = DictationController()

    /// Drives the onboarding window. Lazy so it builds after `dictation` exists,
    /// reusing the controller's already-warmed `DictationSession`.
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession)

    /// Sparkle in-app updater. Lazy because it needs `self` as the user-driver delegate;
    /// `startingUpdater: false` defers the first scheduled check until `startUpdater()`,
    /// which we call in `startMenuApp` — so a daily check can never collide with the
    /// first-run onboarding window.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    private var onboardingWindow: NSWindow?
    private var didStartMenuApp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A unit-test bundle for an app target is loaded *into* the app, so the
        // app launches for every test run. Left alone it would register global
        // hotkeys, raise the microphone prompt and load multi-gigabyte models on
        // the developer's machine — and MLX in Debug crashes doing it. Tests get
        // an inert host: they link the code without the app coming to life.
        if NSClassFromString("XCTestCase") != nil { return }
        // Analytics is optional: no API key → never initialize (e.g. a privacy/App
        // Store build); key present but consent off → set up then opt out, which makes
        // every `capture(…)` a no-op. Audio/transcripts are never sent regardless.
        if !posthogApiKey.isEmpty {
            let config = PostHogConfig(apiKey: posthogApiKey, host: posthogHost)
            config.captureApplicationLifecycleEvents = true
            PostHogSDK.shared.setup(config)
            // Sync PostHog to our consent (opt-in: off until enabled on Welcome).
            if AnalyticsConsent.enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
        }

        // Router: first run → onboarding ONLY, as a REGULAR app (Dock icon, ⌘-Tab,
        // normal focus — so a TCC permission dialog can't bury the window beyond
        // recovery). The live menu app (hotkey, mic prompt, model warm-up) boots —
        // and the app drops to a `.accessory` menu-bar agent — only when onboarding
        // finishes. A returning user goes straight to the menu app.
        onboarding.onFinished = { [weak self] in self?.startMenuApp() }
        onboarding.onReactivate = { [weak self] in self?.presentOnboarding() }
        if OnboardingModel.shouldShow {
            NSApp.setActivationPolicy(.regular)
            PostHogSDK.shared.capture("onboarding_started")
            presentOnboarding()
        } else {
            startMenuApp()
        }
    }

    /// Become the menu-bar agent (no Dock icon) and wire up live dictation. Idempotent
    /// — for a first run this runs once onboarding completes (mic granted, models
    /// cached), for a returning user it runs at launch.
    private func startMenuApp() {
        guard !didStartMenuApp else { return }
        didStartMenuApp = true
        NSApp.setActivationPolicy(.accessory)
        dictation.bootstrap()
        updaterController.startUpdater()   // begin daily update checks now (post-onboarding)
    }

    /// "Check for Updates…" from the menu. As an `.accessory` agent we briefly become a
    /// `.regular` app so Sparkle's dialog takes focus; `standardUserDriverWillFinishUpdateSession`
    /// drops us back. No-op while a check is already in flight.
    func checkForUpdates() {
        guard updaterController.updater.canCheckForUpdates else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate — focus Sparkle's UI for an accessory agent
    // `nonisolated` to satisfy the non-isolated @objc protocol from our @MainActor class;
    // Sparkle invokes these on the main thread, so hopping via assumeIsolated is safe.

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // A scheduled (background) check wants to show UI — surface the app so the dialog
        // isn't buried behind other windows.
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        // Sparkle is done with the user → return to a background menu-bar agent.
        MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
    }

    /// Show (or re-show) the onboarding window. AppKit-owned `NSWindow` rather than a
    /// SwiftUI `Window` scene: a menu-bar (`.accessory`) app can't open a scene window
    /// reliably at launch, and a scene window hides on deactivation. This one persists
    /// (`isReleasedWhenClosed = false`) so "Setup tour…" can re-open it.
    func presentOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Setup tour…" — reset to Welcome, then present.
    func replayOnboarding() {
        onboarding.replay()
        presentOnboarding()
    }

    private func makeOnboardingWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: onboarding).frame(width: 880, height: 640))
        host.safeAreaRegions = []   // content runs under the transparent title bar (our drawn row IS the bar)
        let window = NSWindow(contentViewController: host)
        window.title = NSLocalizedString("Murmator Setup", comment: "Setup window title")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 880, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Closing the setup window before finishing (initial onboarding) cancels setup →
    /// quit, so the app never lingers half-configured. A returning user's "Setup tour…"
    /// replay (menu app already running) just closes the window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        if !didStartMenuApp { NSApp.terminate(nil) }
    }
}
