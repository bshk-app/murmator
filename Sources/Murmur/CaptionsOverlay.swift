import AppKit
import MurmurCaptions
import Observation
import SwiftUI

@MainActor
@Observable
final class CaptionsOverlayModel {
    var appearance = CaptionsAppearance()
    var editing = false
    var confirmed = ""
    var partial = ""
    var translation = ""
    /// Badge tag of the translation language, or `""` when the talk is not
    /// translated — which also takes the translation track off the band.
    var target = ""
    var layout = CaptionsLayout(screen: CGSize(width: 1920, height: 1080), translating: false)
}

private struct CaptionsOverlayView: View {
    let model: CaptionsOverlayModel
    let onFrameChange: (NSRect) -> Void
    let onLock: () -> Void

    var body: some View {
        CaptionsBand(confirmed: model.confirmed, partial: model.partial, translation: model.translation,
                     layout: model.layout, appearance: model.appearance)
        .overlay {
            if model.editing {
                CaptionsInteractionSurface(minimumSize: model.layout.minimumSize, onChange: onFrameChange)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).allowsHitTesting(false))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.editing {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Resize captions")
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.editing {
                Button("Done", action: onLock).buttonStyle(.borderedProminent).padding(5)
            }
        }
    }
}

/// The captions surface: one click-through band on the chosen screen for the
/// whole talk. Separate from `HUDController` by design — the HUD is a progress
/// indicator for one utterance, this is the result itself.
@MainActor
final class CaptionsOverlay {
    // Not private: tests assert on what the band shows and where it sits.
    let model = CaptionsOverlayModel()
    let preferences: CaptionsPreferences
    private var previewing = false
    private var layoutScreen: NSScreen?
    var panelFrame: NSRect? { panel?.frame }
    var acceptsInteraction: Bool { panel?.ignoresMouseEvents == false }
    private var panel: NSPanel?
    /// `CaptionsDisplay` value; the picker stays live, so this can change mid-talk.
    private var display = CaptionsDisplay.followCursor
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    /// Bumped per talk, so a fade-out still running from the previous stop
    /// cannot order out a band that a quick restart just brought back.
    private var presentation = 0
    var isVisible: Bool { panel?.isVisible == true }

    init(defaults: UserDefaults = .standard) {
        preferences = CaptionsPreferences(defaults: defaults)
        model.appearance = preferences.appearance
        preferences.onChange = { [weak self] in
            guard let self else { return }
            self.model.appearance = self.preferences.appearance
            self.layoutPanel(resolveDisplay: false)
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func begin(target: String, display: String) {
        self.display = display
        previewing = false
        model.editing = false
        panel?.ignoresMouseEvents = true
        presentation &+= 1
        model.confirmed = ""
        model.partial = ""
        model.translation = ""
        model.target = target
        let panel = ensurePanel()
        layoutPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
    }

    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
    }

    /// The rolling translation. `""` clears the track, so switching
    /// translation off mid-talk does not freeze the last line on screen.
    func showTranslation(_ text: String) {
        model.translation = text
    }

    /// Follow a Translate-to change mid-talk: the track appears, or goes away
    /// together with its text, and the band resizes once.
    func setTranslationTarget(_ target: String) {
        guard panel != nil else { return }
        model.target = target
        if target.isEmpty { model.translation = "" }
        layoutPanel(resolveDisplay: false)
    }

    func moveToDisplay(_ display: String) {
        self.display = display
        guard panel?.isVisible == true else { return }
        layoutPanel()
    }

    func dismiss() {
        model.editing = false
        previewing = false
        panel?.ignoresMouseEvents = true
        guard let panel else { return }
        let presentation = presentation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentation == presentation else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.title = "Captions"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above a full-screen slideshow; the HUD's `.statusBar` sits under it.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // The audience's screen: nothing on it is for clicking, and a band that
        // swallowed clicks would get in the way of the speaker's own slides.
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CaptionsOverlayView(model: model,
            onFrameChange: { [weak self] in self?.setManualFrame($0) },
            onLock: { [weak self] in self?.setEditing(false) }))
        self.panel = panel
        // A projector plugged in (or yanked) mid-talk: re-resolve so the band
        // lands on the pinned screen once it appears, and falls back to one
        // that still exists when it goes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                self.layoutPanel()
            }
        }
        return panel
    }

    func setEditing(_ editing: Bool, display: String? = nil, translating: Bool = false) {
        if editing && !isVisible {
            self.display = display ?? self.display
            previewing = true
            presentation &+= 1
            model.target = translating ? "preview" : ""
            model.confirmed = "Move this area to place your captions. Resize it using the lower-right corner. Your appearance and position are saved automatically."
            model.partial = ""
            model.translation = translating ? "Translation appears here. You can change its color independently from the original text." : ""
            let panel = ensurePanel()
            layoutPanel()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        model.editing = editing
        panel?.ignoresMouseEvents = !editing
        if !editing && previewing { dismiss() }
    }

    func resetPlacement(display: String) {
        guard let screen = CaptionsDisplay.resolve(display) else { return }
        preferences.resetPlacement(for: screenKey(screen))
    }

    func setManualFrame(_ proposed: NSRect) {
        guard model.editing, let panel, let screen = layoutScreen else { return }
        let frame = CaptionsPlacement.fitted(proposed, visible: screen.visibleFrame, minimum: model.layout.minimumSize)
        preferences.save(frame: frame, on: screenKey(screen), visible: screen.visibleFrame)
        apply(frame: frame, screen: screen)
        panel.setFrame(frame, display: true)
    }

    private func screenKey(_ screen: NSScreen) -> String {
        CaptionsDisplay.uuid(of: screen) ?? screen.localizedName
    }

    private func apply(frame: NSRect, screen: NSScreen) {
        model.layout = CaptionsLayout(screen: screen.frame.size, translating: !model.target.isEmpty,
                                      appearance: preferences.appearance, size: frame.size)
    }

    private func layoutPanel(resolveDisplay: Bool = true) {
        guard let panel else { return }
        let screen: NSScreen
        if !resolveDisplay, let current = layoutScreen, NSScreen.screens.contains(current) {
            screen = current
        } else if let resolved = CaptionsDisplay.resolve(display) {
            screen = resolved
        } else { return }
        layoutScreen = screen
        let layout = CaptionsLayout(screen: screen.frame.size, translating: !model.target.isEmpty,
                                    appearance: preferences.appearance)
        let visible = screen.visibleFrame
        let automatic = NSRect(x: (visible.midX - layout.bandSize.width / 2).rounded(),
                               y: visible.minY + layout.bottomInset,
                               width: layout.bandSize.width, height: layout.bandSize.height)
        let proposed = preferences.placement(for: screenKey(screen))?.frame(in: visible) ?? automatic
        let frame = CaptionsPlacement.fitted(proposed, visible: visible, minimum: layout.minimumSize)
        if preferences.placement(for: screenKey(screen)) == nil {
            model.layout = layout
        } else {
            apply(frame: frame, screen: screen)
        }
        panel.setFrame(frame, display: true)
    }
}
