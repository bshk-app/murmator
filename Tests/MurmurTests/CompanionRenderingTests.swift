import AppKit
import SwiftUI
import MurmurKit
import XCTest
@testable import Murmur

/// Optional artifacts render only our own views, with no microphone, models or global keys.
@MainActor final class CompanionRenderingTests: XCTestCase {
    func testPersistentMainWindowRendersInBothThemes() throws {
        let controller = DictationController(session: FakeDictationSession())
        for (name, theme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(MainControlView(dictation: controller, onSettings: {})
                .environment(\.colorScheme, theme), size: CGSize(width: 500, height: 720), name: "main-window-" + name)
        }
    }
    func testMenuPanelRendersInBothThemes() throws {
        let controller = DictationController(session: FakeDictationSession())
        for (name, theme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(MenuPopover(dictation: controller, onOpenWindow: {}, onSettings: {}, onToggleDictation: {}).environment(\.colorScheme, theme), size: CGSize(width: 296, height: 710), name: "menu-panel-" + name)
        }
    }
    func testHistoricalCaretIndicatorRendersInBothThemes() throws {
        let hud = HUDController()
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        hud.locateCaret = { _ in .found(CaretSpot(
            CGRect(x: visible.midX, y: visible.midY, width: 0, height: 18),
            font: FieldFont(name: "Helvetica", size: 13))) }
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .caret)
        hud.update(confirmed: "Уже распознанные слова", partial: "и быстрый черновик")
        let size = try XCTUnwrap(hud.panelFrame).size
        for (name, theme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(HUDView(model: hud.model).environment(\.colorScheme, theme),
                       size: size, name: "historical-caret-" + name)
        }
        hud.dismiss()
    }

    func testFallbackRealtimeDraftRendersInBothThemes() throws {
        let hud = HUDController()
        hud.locateCaret = { _ in .notFound }
        hud.begin(lang: "RU", interactive: true, confirmsWithReturn: true, style: .caret)
        hud.update(confirmed: "Уже распознанная часть фразы,", partial: "а это быстрый черновик во время речи")
        let size = try XCTUnwrap(hud.previewPanelFrame).size
        for (name, theme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(HUDView(model: hud.model, previewOnly: true).environment(\.colorScheme, theme),
                       size: size, name: "realtime-fallback-" + name)
        }
        hud.dismiss()
    }

    func testStatusAndTourRenderInsideTheirWindows() throws {
        let companion = DictationCompanion.Model()
        companion.message = "Loading speech model…"
        companion.fraction = 0.6
        companion.onCancel = {}
        try render(CompanionView(model: companion).environment(\.colorScheme, .dark),
                   size: CGSize(width: 360, height: 150), name: "companion-loading")

        let model = OnboardingModel(session: FakeDictationSession())
        model.flow.micGranted = true
        model.modelsReady = true
        model.tryConfirmed = "Привет, мир!"
        model.tryTranslation = "Hello, world!"
        model.practiceTranslationTarget = "en"
        model.tryPhase = .done
        for step in OnboardingFlow.Step.allCases {
            model.flow.step = step
            for (name, theme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                try render(OnboardingView(model: model).environment(\.colorScheme, theme),
                           size: CGSize(width: 960, height: 640), name: "onboarding-\(step)-\(name)")
            }
        }
    }

    private func render<Content: View>(_ content: Content, size: CGSize, name: String) throws {
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        if let directory = ProcessInfo.processInfo.environment["MURMUR_UI_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }
}
