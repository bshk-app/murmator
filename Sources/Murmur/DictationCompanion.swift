import AppKit
import Observation
import SwiftUI

/// Feedback for a dictation attempt, including the time before a microphone exists.
@MainActor
final class DictationCompanion {
    @Observable final class Model {
        enum Phase { case preparing, listening, finishing, error }
        var phase: Phase = .preparing
        var message = ""
        var fraction: Double?
        var onCancel: (() -> Void)?
        var mood: MascotMood {
            switch phase {
            case .preparing: .preparing
            case .listening: .listening
            case .finishing: .transcribing
            case .error: .error
            }
        }
    }

    let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var waitGeneration = 0
    /// Ordinary startup/refinement keeps using the existing HUD. The adviser
    /// appears only when an operation is taking noticeably longer.
    var waitDelay: TimeInterval = 3
    var isVisible: Bool { panel?.isVisible == true }
    var frame: CGRect? { panel?.frame }
    var locateCaret: () -> CaretLocator.Lookup = { CaretLocator.locate(readingFont: false) }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    private static let size = CGSize(width: 360, height: 150)

    func preparing(_ message: String, fraction: Double? = nil, onCancel: @escaping () -> Void) {
        wait(.preparing, message: message, fraction: fraction, onCancel: onCancel)
    }

    func updatePreparation(_ message: String, fraction: Double?) {
        guard (isVisible || showWork != nil), model.phase == .preparing else { return }
        model.message = message
        model.fraction = fraction
    }

    func finishing(_ message: String) { wait(.finishing, message: message) }

    func error(_ message: String) {
        cancelPendingShow()
        show(.error, message: message)
        hide(after: 8)
    }

    func dismiss() {
        cancelPendingShow()
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil)
    }

    private func cancelPendingShow() {
        waitGeneration &+= 1
        showWork?.cancel(); showWork = nil
    }

    private func wait(_ phase: Model.Phase, message: String, fraction: Double? = nil,
                      onCancel: (() -> Void)? = nil) {
        hideWork?.cancel(); hideWork = nil
        if isVisible {
            show(phase, message: message, fraction: fraction, onCancel: onCancel)
            return
        }
        model.phase = phase; model.message = message
        model.fraction = fraction; model.onCancel = onCancel
        guard showWork == nil else { return }
        if waitDelay <= 0 {
            show(phase, message: message, fraction: fraction, onCancel: onCancel)
            return
        }
        let generation = waitGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.waitGeneration == generation else { return }
            self.showWork = nil
            self.show(self.model.phase, message: self.model.message,
                      fraction: self.model.fraction, onCancel: self.model.onCancel)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + waitDelay, execute: work)
    }

    private func show(_ phase: Model.Phase, message: String, fraction: Double? = nil,
                      onCancel: (() -> Void)? = nil) {
        hideWork?.cancel(); hideWork = nil
        let reposition = !isVisible || (phase == .preparing && model.phase != .preparing)
        model.phase = phase
        model.message = message
        model.fraction = fraction
        model.onCancel = onCancel
        let panel = ensurePanel()
        panel.ignoresMouseEvents = onCancel == nil
        if reposition {
            let anchor: CGRect
            if case .found(let spot) = locateCaret() { anchor = spot.caret }
            else { anchor = CGRect(origin: pointer(), size: .zero) }
            let screens = NSScreen.screens
            let screen = HUDController.screenIndex(containing: anchor, in: screens.map(\.frame))
                .map { screens[$0] } ?? NSScreen.main
            if let screen {
                panel.setFrame(Self.placement(near: anchor, visible: screen.visibleFrame), display: true)
            }
        }
        panel.orderFrontRegardless()
    }

    /// Prefer the space below the caret; switch above it at the display edge.
    static func placement(near anchor: CGRect, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let proposedY = anchor.minY - height - 10
        let y = proposedY >= visible.minY ? proposedY : anchor.maxY + 10
        return CGRect(x: min(max(anchor.minX - 38, visible.minX), visible.maxX - width),
                      y: min(max(y, visible.minY), visible.maxY - height), width: width, height: height)
    }

    private func hide(after seconds: Double) {
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: CompanionView(model: model))
        self.panel = panel
        return panel
    }
}

struct CompanionView: View {
    let model: DictationCompanion.Model
    @Environment(\.colorScheme) private var scheme

    private var t: OnTheme { OnTheme(scheme) }
    private var isError: Bool { model.phase == .error }

    private var title: LocalizedStringKey {
        switch model.phase {
        case .preparing: "Still getting ready…"
        case .finishing: "Still finishing…"
        case .listening: "Murmator"
        case .error: "Dictation error"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(t.ink)
                Text(verbatim: model.message)
                    .font(.system(size: 11.5)).foregroundStyle(t.muted(0.7))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if model.phase == .preparing {
                    Group {
                        if let fraction = model.fraction {
                            ProgressView(value: min(1, max(0, fraction)))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .tint(Mur.accent).padding(.top, 4)
                    if let cancel = model.onCancel {
                        Button("Cancel loading", action: cancel)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.accentText)
                            .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(width: 300, alignment: .leading)
        .background(Mur.glass(scheme), in: .rect(cornerRadius: 14))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(isError ? Mur.error : t.line(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-companion")
    }

    private var icon: some View {
        MurmatorMascot(mood: model.mood, size: 28)
            .frame(width: 34, height: 34)
            .background(t.line(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if isError {
                    Text(verbatim: "!")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 12, height: 12)
                        .background(Mur.error, in: Circle())
                        .offset(x: 3, y: 2)
                        .accessibilityHidden(true)
                }
            }
    }
}
