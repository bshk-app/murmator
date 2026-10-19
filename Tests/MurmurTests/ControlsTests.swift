import AppKit
import SwiftUI
import XCTest
@testable import Murmur
@testable import MurmurKit

/// The menu bar panel and the window share one set of settings and one
/// controller; these pin what both surfaces show and what a change runs.
@MainActor
final class ControlsTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [AppMode.defaultsKey, ModelSetting.key, SpeechLanguage.defaultsKey, TranslationSetting.key,
                        ModelLoadingPolicy.key, DictationEnabled.key, TriggerMode.defaultsKey,
                        ControlSettingsObserver.correctorKey]

    override func setUpWithError() throws {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(AppMode.dictation.rawValue, forKey: AppMode.defaultsKey)
        UserDefaults.standard.set(DictationMode.hybrid.rawValue, forKey: ModelSetting.key)
        UserDefaults.standard.set("en", forKey: SpeechLanguage.defaultsKey)
        UserDefaults.standard.set(TranslationSetting.off, forKey: TranslationSetting.key)
        UserDefaults.standard.set(ModelLoadingPolicy.atLaunch.rawValue, forKey: ModelLoadingPolicy.key)
        UserDefaults.standard.set(true, forKey: DictationEnabled.key)
    }

    override func tearDownWithError() throws {
        for key in keys {
            if let value = saved[key], let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testAModeChangePreparesOnceWhicheverSurfaceWroteIt() async {
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        let observer = ControlSettingsObserver(dictation: controller)
        await settle()
        let before = fake.prepareCount

        UserDefaults.standard.set(DictationMode.fast.rawValue, forKey: ModelSetting.key)
        await until { fake.prepareCount > before }
        XCTAssertEqual(fake.prepareCount, before + 1)

        UserDefaults.standard.set(TriggerMode.toggle.rawValue, forKey: TriggerMode.defaultsKey)
        UserDefaults.standard.set(DictationMode.fast.rawValue, forKey: ModelSetting.key)
        await settle()
        XCTAssertEqual(fake.prepareCount, before + 1, "an unrelated key or the same value prepares nothing")
        withExtendedLifetime(observer) {}
    }

    func testTheCorrectorSwitchPreparesTheCurrentMode() async {
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        let observer = ControlSettingsObserver(dictation: controller)
        await settle()
        let before = fake.prepareCount
        let on = UserDefaults.standard.bool(forKey: ControlSettingsObserver.correctorKey)
        UserDefaults.standard.set(!on, forKey: ControlSettingsObserver.correctorKey)
        await until { fake.prepareCount > before }
        XCTAssertEqual(fake.prepareCount, before + 1)
        withExtendedLifetime(observer) {}
    }

    func testStartFollowsTheMasterSwitchAndNamesCaptions() {
        let controller = DictationController(session: FakeDictationSession())
        var action = PrimaryDictationAction.current(controller)
        XCTAssertEqual(action.kind, .start)
        XCTAssertFalse(action.disabled)
        XCTAssertEqual(action.title, String(localized: "Start dictation"))

        UserDefaults.standard.set(AppMode.captions.rawValue, forKey: AppMode.defaultsKey)
        XCTAssertEqual(PrimaryDictationAction.current(controller).title, String(localized: "Start captions"))

        UserDefaults.standard.set(false, forKey: DictationEnabled.key)
        action = PrimaryDictationAction.current(controller)
        XCTAssertTrue(action.disabled, "Start follows the master switch, like the shortcut")
        XCTAssertEqual(ControlsStatus.current(controller, detailed: true).tone, .off)
    }

    func testRecordingShowsStopAndListening() async {
        let fake = FakeDictationSession()
        let controller = DictationController(session: fake)
        controller.companion.waitDelay = 0
        controller.toggleFromMenu()
        await controller.recordingTask?.value
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(PrimaryDictationAction.current(controller).kind, .stop)
        XCTAssertEqual(StatusIconRenderer.state(controller), .listening)
        controller.toggleFromMenu()
        await controller.recordingTask?.value
    }

    func testStopFromTheWindowAlsoReturnsFocus() {
        XCTAssertTrue(ControlsFocus.returnsFocus(appIsActive: true, starting: false, managingModels: false),
                      "Start and Stop both type into the app that was in front")
        XCTAssertFalse(ControlsFocus.returnsFocus(appIsActive: false, starting: false, managingModels: false),
                       "in the background a stale app must not steal focus")
        XCTAssertFalse(ControlsFocus.returnsFocus(appIsActive: true, starting: true, managingModels: false))
        XCTAssertFalse(ControlsFocus.returnsFocus(appIsActive: true, starting: false, managingModels: true))
    }

    func testALateToggleYieldsToAShortcutThatActedFirst() {
        XCTAssertTrue(ControlsFocus.stillWanted(wasActive: false, isActive: false, starting: false))
        XCTAssertTrue(ControlsFocus.stillWanted(wasActive: true, isActive: true, starting: false))
        XCTAssertFalse(ControlsFocus.stillWanted(wasActive: false, isActive: true, starting: false),
                       "a Start queued behind the shortcut's Start would stop that recording")
        XCTAssertFalse(ControlsFocus.stillWanted(wasActive: false, isActive: false, starting: true),
                       "a second Start would cancel the first one's warm-up")
        XCTAssertFalse(ControlsFocus.stillWanted(wasActive: true, isActive: false, starting: false))
    }

    func testOnlyRealWindowsKeepTheDockIcon() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let hud = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                          styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        hud.isReleasedWhenClosed = false
        hud.orderFront(nil)
        defer { hud.orderOut(nil) }
        XCTAssertFalse(AppPresence.needsDock([window, hud]), "a HUD alone leaves Murmator a menu bar agent")
        window.orderFront(nil)
        XCTAssertTrue(AppPresence.needsDock([window, hud]))
        window.close()
        XCTAssertFalse(AppPresence.needsDock([window, hud]), "closing Settings or the window leaves the Dock")
    }

    /// An unplugged microphone shows System default, but its saved choice
    /// stays, so it is used again when it is plugged back in.
    func testADisconnectedMicrophoneKeepsItsSavedChoice() throws {
        let saved = UserDefaults.standard.object(forKey: MicrophoneSetting.defaultsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: MicrophoneSetting.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: MicrophoneSetting.defaultsKey) }
        }
        UserDefaults.standard.set("unplugged-usb-mic", forKey: MicrophoneSetting.defaultsKey)
        XCTAssertEqual(MicrophoneChoice.shown("unplugged-usb-mic", devices: []), MicrophoneSetting.systemDefaultUID)
        let controller = DictationController(session: FakeDictationSession())
        try render(MenuPopover(dictation: controller, onOpenWindow: {}, onSettings: {}, onToggleDictation: {}),
                   size: CGSize(width: 296, height: 560), name: "menu-panel-unplugged")
        try render(MainControlView(dictation: controller, onSettings: {}),
                   size: CGSize(width: 500, height: 720), name: "main-window-unplugged")
        XCTAssertEqual(UserDefaults.standard.string(forKey: MicrophoneSetting.defaultsKey), "unplugged-usb-mic")
    }

    func testTheMenuBarIconWidensOnlyForActivity() {
        let artwork = MascotStyle.defaultStyle.artworkName(hasMoustache: true)
        XCTAssertEqual(StatusIconRenderer.image(.idle, artwork: artwork).size.width, 18)
        XCTAssertEqual(StatusIconRenderer.image(.off, artwork: artwork).size.width, 18)
        XCTAssertEqual(StatusIconRenderer.image(.listening, artwork: artwork).size.width, 26)
        XCTAssertFalse(StatusIconRenderer.image(.idle, artwork: artwork).isTemplate, "the mascot keeps its colours")
    }

    func testStatusIconUsesOneHeadFromTheSelectedAtlas() throws {
        // Green upper-left pose, red everywhere else: shrinking the whole
        // atlas turns the icon's middle red, which catches the reported bug.
        let width = 300, height = 200
        var rgba: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { rgba += x < 100 && y < 100 ? [0, 255, 0, 255] : [255, 0, 0, 255] }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let pixels = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let sheet = NSImage(cgImage: pixels, size: NSSize(width: width, height: height))
        let name = NSImage.Name("status-test-\(UUID())"); sheet.setName(name)
        let icon = StatusIconRenderer.image(.idle, artwork: name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(icon.tiffRepresentation)))
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.greenComponent, 0.95)
        XCTAssertLessThan(center.redComponent, 0.05)
    }

    func testOnlyVerifiedTargetsAreOffered() {
        let targets = ControlsChoices.targets(dictating: "ru")
        XCTAssertEqual(targets.first, TranslationSetting.off)
        XCTAssertEqual(Array(targets.dropFirst()), TranslationSetting.offered(dictating: "ru"))
    }

    /// The window renders in CompanionRenderingTests.
    func testMenuBarPanelRendersInBothAppearances() throws {
        let controller = DictationController(session: FakeDictationSession())
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(MenuPopover(dictation: controller, onOpenWindow: {}, onSettings: {}, onToggleDictation: {})
                .environment(\.colorScheme, scheme), size: CGSize(width: 296, height: 560), name: "menu-panel-" + name)
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
        if let directory = ProcessInfo.processInfo.environment["MURMUR_UI_ARTIFACTS"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent(name + ".png"))
        }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<50 { await Task.yield() }
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "The settings change did not reach the controller")
    }
}
