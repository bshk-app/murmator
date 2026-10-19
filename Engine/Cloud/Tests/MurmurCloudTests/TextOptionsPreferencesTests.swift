import Foundation
import XCTest
import AIProvidersCore
@testable import MurmurCloud

@MainActor final class TextOptionsPreferencesTests: XCTestCase {
    private func fixture(provider: String = "openrouter", body: (ProviderPreferences, AIConnection, UserDefaults) throws -> Void) throws {
        let namespace = "text-options-\(UUID())"
        let suite = "text-options-fixture-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let connection = AIConnection(provider: provider, name: "Fixture", endpoint: URL(string: "https://fixture.example/v1")!)
        let model = AIModel(id: "any/model", name: "Fixture", kind: .text, operations: [.textEditing, .translation],
                            reasoning: .init(supportedEfforts: [.low, .medium, .high], mandatory: true))
        defaults.set(try JSONEncoder().encode([connection]), forKey: "ai.connections.v1")
        defaults.set(try JSONEncoder().encode([connection.id.uuidString: [model]]), forKey: "ai.catalogs.v1")
        defaults.set(try JSONEncoder().encode(["textEditing": AISelection(connectionID: connection.id, modelID: model.id),
                                               "translation": AISelection(connectionID: connection.id, modelID: model.id)]), forKey: "ai.selections.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProviderPreferences(defaults: defaults, vault: .init(service: namespace))
        try body(preferences, connection, defaults)
    }

    func testOptionsPersistPerStepAndChangeSessionFingerprintWithoutChangingModels() throws {
        try fixture { preferences, connection, defaults in
            let original = preferences.configurationID
            let options = AITextOptions(reasoningEffort: .low, routing: .init(sort: .latency, only: ["groq"], allowFallbacks: false))
            try preferences.setTextOptions(options, for: .textEditing)
            XCTAssertNotEqual(preferences.configurationID, original)
            XCTAssertEqual(preferences.selection(.textEditing)?.connectionID, connection.id)
            XCTAssertEqual(preferences.selection(.textEditing)?.modelID, "any/model")
            XCTAssertNil(preferences.selection(.translation)?.options)
            let reloaded = ProviderPreferences(defaults: defaults)
            XCTAssertEqual(reloaded.selection(.textEditing)?.options, options)
            XCTAssertEqual(reloaded.configurationID, preferences.configurationID)
            try preferences.setTextOptions(.init(), for: .textEditing)
            XCTAssertEqual(preferences.configurationID, original)
        }
    }

    func testUnsupportedEffortAndInvalidServerCannotReplaceExistingOptions() throws {
        try fixture { preferences, _, _ in
            try preferences.setTextOptions(.init(reasoningEffort: .low), for: .textEditing)
            let original = preferences.configurationID
            XCTAssertThrowsError(try preferences.setTextOptions(.init(reasoningEffort: AIReasoningEffort.none), for: .textEditing))
            XCTAssertThrowsError(try preferences.setTextOptions(.init(routing: .init(only: ["https://bad.example"])), for: .textEditing))
            XCTAssertEqual(preferences.configurationID, original)
        }
    }

    func testDirectServicesRejectRoutingWithoutChangingSelection() throws {
        try fixture(provider: "openaiCompatible") { preferences, _, _ in
            let original = preferences.configurationID
            XCTAssertThrowsError(try preferences.setTextOptions(.init(routing: .init(sort: .latency)), for: .textEditing))
            XCTAssertEqual(preferences.configurationID, original)
            try preferences.setTextOptions(.init(reasoningEffort: .low), for: .textEditing)
            XCTAssertEqual(preferences.selection(.textEditing)?.options?.reasoningEffort, .low)
        }
    }

    func testMissingCatalogDoesNotEraseCurrentModelWhileTuningIt() throws {
        try fixture { preferences, connection, defaults in
            defaults.removeObject(forKey: "ai.catalogs.v1")
            let withoutCatalog = ProviderPreferences(defaults: defaults)
            try withoutCatalog.setTextOptions(.init(reasoningEffort: .low), for: .textEditing)
            XCTAssertEqual(withoutCatalog.selection(.textEditing)?.connectionID, connection.id)
            XCTAssertEqual(withoutCatalog.selection(.textEditing)?.modelID, "any/model")
            XCTAssertEqual(withoutCatalog.selection(.textEditing)?.options?.reasoningEffort, .low)
            XCTAssertEqual(preferences.selection(.textEditing)?.options, nil)
        }
    }
}
