import Foundation
import XCTest
import AIProvidersCore
import AIProvidersAuth
@testable import MurmurCloud

@MainActor final class ProviderPreferencesTests: XCTestCase {
    func testCRUDKeepsIdentityAndCredentialsAndInvalidatesSelectedEndpoint() throws {
        let namespace = "murmur-provider-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        let vault = AICredentialVault(service: namespace)
        let connection = AIConnection(provider: "openai", name: "First", endpoint: URL(string: "https://first.example/v1")!)
        let preferences = ProviderPreferences(defaults: defaults, vault: vault)
        defer { try? preferences.remove(connection.id); defaults.removePersistentDomain(forName: namespace) }
        try preferences.add(connection, key: "synthetic-key-one")
        defaults.set(try JSONEncoder().encode([AIOperation.textEditing.rawValue: AISelection(connectionID: connection.id, modelID: "gpt-test")]), forKey: "ai.selections.v1")
        defaults.set(try JSONEncoder().encode([connection.id.uuidString: [AIModel(id: "gpt-test", name: "Test", kind: .text, operations: [.textEditing])]]), forKey: "ai.catalogs.v1")
        let loaded = ProviderPreferences(defaults: defaults, vault: vault)
        let before = loaded.configurationID
        var edited = connection
        edited.name = "Renamed"
        try loaded.update(edited)
        XCTAssertEqual(loaded.connections.first?.id, connection.id)
        XCTAssertEqual(try vault.token(connection.id), "synthetic-key-one")
        XCTAssertEqual(loaded.configurationID, before, "renaming does not reload models")
        XCTAssertEqual(loaded.catalogs[connection.id.uuidString]?.count, 1)
        try loaded.update(edited, key: "")
        XCTAssertEqual(try vault.token(connection.id), "synthetic-key-one", "empty edit keeps the saved key")
        edited.endpoint = URL(string: "https://second.example/v1")!
        try loaded.update(edited, key: "synthetic-key-two")
        XCTAssertNotEqual(loaded.configurationID, before)
        XCTAssertEqual(try vault.token(connection.id), "synthetic-key-two")
        XCTAssertNil(loaded.catalogs[connection.id.uuidString], "a catalog from the previous endpoint cannot be offered as current")
        XCTAssertEqual(loaded.selection(.textEditing)?.modelID, "gpt-test", "never silently pick a different model")
        let changed = loaded.configurationID
        try loaded.update(edited, key: "synthetic-key-three")
        XCTAssertNotEqual(loaded.configurationID, changed, "new credentials take effect even at the same endpoint")
        try loaded.remove(connection.id)
        XCTAssertTrue(loaded.connections.isEmpty)
        XCTAssertNil(loaded.selection(.textEditing))
        XCTAssertThrowsError(try vault.read(connection.id))
    }

    func testInvalidUpdateCannotChangeStoredMetadataOrKey() throws {
        let namespace = "murmur-provider-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        let vault = AICredentialVault(service: namespace)
        let preferences = ProviderPreferences(defaults: defaults, vault: vault)
        let connection = AIConnection(provider: "openai", name: "Original", endpoint: URL(string: "https://first.example/v1")!)
        defer { try? preferences.remove(connection.id); defaults.removePersistentDomain(forName: namespace) }
        try preferences.add(connection, key: "synthetic-original")
        var edited = connection
        edited.endpoint = URL(string: "http://insecure.example/v1")!
        XCTAssertThrowsError(try preferences.update(edited, key: "must-not-save"))
        edited = connection; edited.provider = "anthropic"
        XCTAssertThrowsError(try preferences.update(edited, key: "must-not-save"))
        XCTAssertEqual(preferences.connections, [connection])
        XCTAssertEqual(try vault.token(connection.id), "synthetic-original")
    }

    func testPlanAccountCanBeRenamedButCannotBeRedirectedOrGivenAnAPIKey() throws {
        let namespace = "murmur-provider-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        defer { defaults.removePersistentDomain(forName: namespace) }
        let connection = AIConnection(provider: "openai", name: "Plan", endpoint: URL(string: "https://api.openai.com/v1")!, auth: .chatGPTPlan)
        defaults.set(try JSONEncoder().encode([connection]), forKey: "ai.connections.v1")
        let preferences = ProviderPreferences(defaults: defaults, vault: .init(service: namespace))
        var renamed = connection; renamed.name = "Work plan"
        try preferences.update(renamed)
        XCTAssertEqual(preferences.connections.first?.name, "Work plan")
        renamed.endpoint = URL(string: "https://custom.example/v1")!
        XCTAssertThrowsError(try preferences.update(renamed))
        XCTAssertThrowsError(try preferences.update(connection, key: "must-not-save"))
    }
}
