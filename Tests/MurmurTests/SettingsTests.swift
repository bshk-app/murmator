import AppKit
import SwiftUI
import XCTest
import MurmurCloud
@testable import Murmur

/// Settings is a sidebar of pages; Settings → Providers from the panel and
/// the window must land on the Providers page, also on the very first open.
@MainActor
final class SettingsTests: XCTestCase {
    private let defaults = UserDefaults(suiteName: "SettingsTests")!

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SettingsTests")
        super.tearDown()
    }

    func testARequestedSectionOpensItsPageOnce() {
        defaults.set("providers", forKey: SettingsTab.requestKey)
        XCTAssertEqual(SettingsTab.takeRequest(defaults), .providers)
        XCTAssertNil(SettingsTab.takeRequest(defaults), "a later plain open keeps the page the user chose")
    }

    func testAnUnknownRequestIsDropped() {
        defaults.set("billing", forKey: SettingsTab.requestKey)
        XCTAssertNil(SettingsTab.takeRequest(defaults))
        XCTAssertNil(defaults.string(forKey: SettingsTab.requestKey))
        XCTAssertNil(SettingsTab(request: nil))
    }

    func testEveryPageIsInTheSidebarOnce() {
        let listed = SettingsTab.groups.flatMap { $0 }
        XCTAssertEqual(Set(listed), Set(SettingsTab.allCases))
        XCTAssertEqual(listed.count, SettingsTab.allCases.count)
    }

    /// Lays out and draws every page without trapping; what it looks like is
    /// checked from the MURMUR_UI_ARTIFACTS images, not here.
    func testEveryPageRendersInBothAppearances() throws {
        let controller = DictationController(session: FakeDictationSession())
        for tab in SettingsTab.allCases {
            for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
                try render(SettingsView(dictation: controller, tab: tab).environment(\.colorScheme, scheme),
                           name: "settings-\(tab.rawValue)-\(name)", scheme: scheme)
            }
        }
    }

    func testProviderModelsAndConnectionEditorRenderInBothAppearances() throws {
        let suite = "ProviderRendering-\(UUID())"
        let stored = UserDefaults(suiteName: suite)!
        defer { stored.removePersistentDomain(forName: suite) }
        let connection = AIConnection(provider: "openai", name: "Personal OpenAI", endpoint: URL(string: "https://api.openai.com/v1")!)
        stored.set(try JSONEncoder().encode([connection]), forKey: "ai.connections.v1")
        stored.set(try JSONEncoder().encode([connection.id.uuidString: [AIModel(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", kind: .text, operations: [.textEditing, .translation])]]), forKey: "ai.catalogs.v1")
        stored.set(try JSONEncoder().encode([AIOperation.textEditing.rawValue: AISelection(connectionID: connection.id, modelID: "gpt-5.6-terra")]), forKey: "ai.selections.v1")
        let preferences = ProviderPreferences(defaults: stored, vault: .init(service: suite))
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(ProviderConnectionsSettingsView(preferences: preferences, checks: ProviderChecks()).padding(24).environment(\.colorScheme, scheme), name: "provider-connections-\(name)", scheme: scheme)
            try render(ProviderModelsSettingsView(preferences: preferences).padding(24).environment(\.colorScheme, scheme), name: "provider-models-\(name)", scheme: scheme)
            try render(ConnectionEditor(draft: .edit(connection), preferences: preferences, saved: { _, _ in }, cancel: {}).environment(\.colorScheme, scheme), name: "provider-edit-\(name)", size: CGSize(width: 480, height: 340), scheme: scheme)
        }
    }

    func testExpandedReasoningAndRoutingRendersInBothAppearances() throws {
        let suite = "TextOptionsRendering-\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let connection = AIConnection(provider: "openrouter", name: "OpenRouter", endpoint: URL(string: "https://openrouter.ai/api/v1")!)
        let model = AIModel(id: "openai/gpt-oss-120b", name: "GPT-OSS 120B", kind: .text, operations: [.textEditing],
                            reasoning: .init(supportedEfforts: [.high, .medium, .low], mandatory: true))
        isolated.set(try JSONEncoder().encode([connection]), forKey: "ai.connections.v1")
        isolated.set(try JSONEncoder().encode([connection.id.uuidString: [model]]), forKey: "ai.catalogs.v1")
        isolated.set(try JSONEncoder().encode(["textEditing": AISelection(connectionID: connection.id, modelID: model.id,
            options: .init(reasoningEffort: .low, routing: .init(only: ["groq"], allowFallbacks: false)))]), forKey: "ai.selections.v1")
        let preferences = ProviderPreferences(defaults: isolated, vault: .init(service: suite))
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try render(ProviderTextOptions(operation: .textEditing, connection: connection, preferences: preferences, onChange: {}, initiallyExpanded: true)
                .padding(24).environment(\.colorScheme, scheme), name: "model-options-\(name)", size: CGSize(width: 560, height: 550), scheme: scheme)
        }
    }

    private func render<Content: View>(_ content: Content, name: String, size: CGSize = CGSize(width: 780, height: 600), scheme: ColorScheme? = nil) throws {
        let view = NSHostingView(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        if let scheme { window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
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
}
