import AppKit
import SwiftUI
import XCTest
import AIProviderViews
import AIProvidersCore

@MainActor final class ProviderModelBrowserTests: XCTestCase {
    func testSearchBrowserRendersLoadedModelsAndKeepsCurrentSelectionInBothThemes() async throws {
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let browser = AIModelBrowser(title: "Corrector model · Featherless", message: "Search by model name or ID.", selectedModelID: "Qwen/Qwen3-8B", selectedModelName: "Qwen3 8B", search: { _, _ in
                .init(models: [.init(id: "Qwen/Qwen3-8B", name: "Qwen3 8B", kind: .text, operations: [.textEditing], contextLength: 32768),
                               .init(id: "meta-llama/Llama-3.3-70B-Instruct", name: "Llama 3.3 70B Instruct", kind: .text, operations: [.textEditing], contextLength: 131072),
                               .init(id: "vendor/unavailable", name: "Unavailable model", kind: .text, operations: [.textEditing], available: false)], nextCursor: "2", total: 52119)
            }, onSelect: { _ in XCTFail("Rendering must not select a model") }, onCancel: {})
            let view = NSHostingView(rootView: browser.environment(\.colorScheme, scheme).tint(.orange).background(Color(nsColor: .windowBackgroundColor)))
            let size = CGSize(width: 540, height: 580)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view; view.frame = CGRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["MURMUR_UI_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("model-browser-\(name).png"))
            }
            window.contentView = nil
        }
    }
}
