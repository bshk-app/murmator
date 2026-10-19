import AppKit
import MurmurKit
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
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession, controller: dictation)

    /// Sparkle in-app updater. Lazy because it needs `self` as the user-driver delegate;
    /// `startingUpdater: false` defers the first scheduled check until `startUpdater()`,
    /// which we call in `startMenuApp` — so a daily check can never collide with the
    /// first-run onboarding window.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    private var onboardingWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    /// Runs a settings change's side effects once, whichever surface made it.
    private var settingsObserver: ControlSettingsObserver?
    var openSettingsAction: (() -> Void)?
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
        onboarding.onFinished = { [weak self] in
            guard let self else { return }
            self.startMenuApp()
            self.onboardingWindow?.close()
            self.presentMainWindow()
        }
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                          app.bundleIdentifier != "com.apple.loginwindow" else { return }
                    self?.lastExternalApplication = app
                }
            }
        settingsObserver = ControlSettingsObserver(dictation: dictation)
        // Settings is a SwiftUI scene window, so no delegate of ours sees it close.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, AppPresence.counts(window) else { return }
                MainActor.assumeIsolated {
                    Task { await Task.yield(); self?.updateActivationPolicy() }
                }
            }
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
        MainActor.assumeIsolated { self.updateActivationPolicy() }
    }

    /// Show (or re-show) the onboarding window. AppKit-owned `NSWindow` rather than a
    /// SwiftUI `Window` scene: a menu-bar (`.accessory`) app can't open a scene window
    /// reliably at launch, and a scene window hides on deactivation. This one persists
    /// (`isReleasedWhenClosed = false`) so "Setup tour…" can re-open it.
    func presentOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        onboarding.isTourFocused = { [weak self] in
            NSApp.isActive && NSApp.keyWindow === self?.onboardingWindow
        }
        onboarding.acquireTourSession()
        dictation.installKeyTap()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Setup tour…" — reset to Welcome, then present.
    func replayOnboarding() {
        if onboardingWindow?.isVisible == true {
            presentOnboarding()
            return
        }
        guard !dictation.isActive, !dictation.isStartingRecording else {
            dictation.companion.error(String(localized: "Finish the current dictation before trying setup."))
            return
        }
        onboarding.replay()
        presentOnboarding()
    }

    private func makeOnboardingWindow() -> NSWindow {
        let host = NSHostingController(rootView: OnboardingView(model: onboarding).frame(width: 960, height: 640))
        host.safeAreaRegions = []   // content runs under the transparent title bar (our drawn row IS the bar)
        let window = NSWindow(contentViewController: host)
        window.title = NSLocalizedString("Murmator Setup", comment: "Setup window title")
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 960, height: 640))
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        window.center()
        return window
    }

    /// Closing the setup window before finishing (initial onboarding) cancels setup →
    /// quit, so the app never lingers half-configured. A returning user's "Setup tour…"
    /// replay (menu app already running) just closes the window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        onboarding.leaveCaretDemo()
        Task { await onboarding.releaseTourSession() }
        if !didStartMenuApp { NSApp.terminate(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        onboarding.tourLostFocus()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        onboarding.acquireTourSession()
    }

    /// The app the user was in, so Start dictation from our controls types there.
    func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           app.bundleIdentifier != "com.apple.loginwindow" { lastExternalApplication = app }
    }

    func presentMainWindow() {
        rememberFrontmostApp()
        if mainWindow == nil {
            let view = MainControlView(dictation: dictation,
                onSettings: { [weak self] in self?.presentSettings() },
                onProviders: { [weak self] in self?.presentSettings(section: "providers") },
                onToggleDictation: { [weak self] in self?.toggleDictationFromControls() })
            let host = NSHostingController(rootView: view)
            // Title, subtitle (the status) and the toolbar's Start button come from SwiftUI.
            host.sceneBridgingOptions = [.title, .toolbars]
            let window = NSWindow(contentViewController: host)
            window.title = "Murmator"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 500, height: 720))
            window.contentMinSize = NSSize(width: 460, height: 420)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.setFrameAutosaveName("MurmatorMain")
            window.center()
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens Settings; `section` (e.g. `"providers"`) is posted for Settings to scroll to.
    func presentSettings(section: String? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Settings reads and clears this on appear: a first open has no view yet to receive the notification.
        if let section { UserDefaults.standard.set(section, forKey: "murmator.settings.requestedSection") }
        openSettingsAction?()
        if let section {
            NotificationCenter.default.post(name: .murmatorShowSettingsSection, object: section)
        }
    }

    /// The Dock menu while the window keeps Murmator in the Dock: the same
    /// primary action and mode as the menu bar panel.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let action = PrimaryDictationAction.current(dictation)
        let primary = NSMenuItem(title: action.title, action: #selector(dockToggleDictation), keyEquivalent: "")
        primary.target = self
        primary.isEnabled = !action.disabled
        menu.addItem(primary)
        menu.addItem(.separator())
        for mode in DictationMode.available(for: SpeechLanguage.current) {
            let item = NSMenuItem(title: ControlsChoices.modeName(mode), action: #selector(dockSelectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = ModelSetting.current == mode ? .on : .off
            item.isEnabled = dictation.canChangeModels
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let window = NSMenuItem(title: String(localized: "Open Murmator Window"), action: #selector(dockOpenWindow), keyEquivalent: "")
        window.target = self
        menu.addItem(window)
        return menu
    }

    @objc private func dockToggleDictation() { toggleDictationFromControls() }
    @objc private func dockOpenWindow() { presentMainWindow() }
    @objc private func dockSelectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: ModelSetting.key)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if didStartMenuApp { presentMainWindow() } else { presentOnboarding() }
        return true
    }

    func toggleDictationFromControls() {
        guard ControlsFocus.returnsFocus(appIsActive: NSApp.isActive, starting: dictation.isStartingRecording,
                                         managingModels: dictation.isManagingModels),
              let target = lastExternalApplication, !target.isTerminated else {
            dictation.toggleFromMenu()
            return
        }
        let wasActive = dictation.isActive
        target.activate(options: [])
        Task {
            // Activation is asynchronous; resolve the caret (on Start) or paste
            // (on Stop) in the target app, not in Murmator.
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            // A shortcut may have started or stopped meanwhile; a late toggle would undo it.
            guard ControlsFocus.stillWanted(wasActive: wasActive, isActive: dictation.isActive,
                                            starting: dictation.isStartingRecording) else { return }
            dictation.toggleFromMenu()
        }
    }

    /// In the Dock while a real window (Murmator, Settings, setup, an update
    /// dialog) is open; a menu bar agent again once the last one closes.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(AppPresence.needsDock(NSApp.windows) ? .regular : .accessory)
    }
}
