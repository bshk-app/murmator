import XCTest
import Foundation
import AIProvidersCore
import AIProvidersAuth
@testable import MurmurCloud

private final class CatalogHTTP: URLProtocol, @unchecked Sendable {
    static var respond: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor final class ProviderCatalogTests: XCTestCase {
    private func fixture(_ body: (ProviderPreferences) async throws -> Void) async throws {
        let namespace = "murmur-catalog-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogHTTP.self]
        let preferences = ProviderPreferences(defaults: defaults, vault: .init(service: namespace), http: .init(session: URLSession(configuration: config)))
        defer { for connection in preferences.connections { try? preferences.remove(connection.id) }; defaults.removePersistentDomain(forName: namespace) }
        try await body(preferences)
    }
    func testMigrationPreservesIDsKeysSelectionsAndClearsWrongCatalog() throws {
        let namespace = "murmur-catalog-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        defer { defaults.removePersistentDomain(forName: namespace) }
        let featherless = AIConnection(provider: "openai", name: "My Featherless", endpoint: URL(string: "https://api.featherless.ai/v1")!)
        let dictator = AIConnection(provider: "dictator", name: "My Dictator", endpoint: URL(string: "https://gateway.example/v1/audio/transcriptions")!)
        let saved = AISelection(connectionID: featherless.id, modelID: "gpt-oss-120b")
        defaults.set(try JSONEncoder().encode([featherless, dictator]), forKey: "ai.connections.v1")
        defaults.set(try JSONEncoder().encode(["textEditing": saved]), forKey: "ai.selections.v1")
        defaults.set(try JSONEncoder().encode([featherless.id.uuidString: [AIModel(id: "gpt-oss-120b", name: "Old", kind: .text, operations: [.textEditing])]]), forKey: "ai.catalogs.v1")
        let preferences = ProviderPreferences(defaults: defaults, vault: .init(service: namespace))
        XCTAssertEqual(preferences.connections.map(\.id), [featherless.id, dictator.id])
        XCTAssertEqual(preferences.connections.map(\.provider), ["featherless", "dictator"])
        XCTAssertEqual(preferences.connections[1].endpoint.path, "/v1")
        XCTAssertEqual(preferences.selection(.textEditing), saved)
        XCTAssertNil(preferences.catalogs[featherless.id.uuidString])
        // No key read/write: migration operates solely on metadata.
        XCTAssertEqual(ProviderPreferences(defaults: defaults).connections, preferences.connections)
    }
    func testFeatherlessChecksAuthenticationThenSearchesFullCatalogInPages() async throws {
        try await fixture { preferences in
            let connection = AIConnection(provider: "featherless", name: "Featherless", endpoint: URL(string: "https://api.featherless.ai/v1")!)
            try preferences.add(connection, key: "synthetic")
            var paths: [String] = []
            CatalogHTTP.respond = { request in
                paths.append(request.url!.path)
                if request.url!.path.hasSuffix("/plan") { return (200, Data(#"{"id":"fixture-plan"}"#.utf8)) }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let name = query.first { $0.name == "q" }?.value ?? "initial"
                let page = query.first { $0.name == "page" }!.value!
                return (200, try JSONSerialization.data(withJSONObject: ["data":[["id":"\(name)/\(page)"]], "pagination":["current_page":Int(page)!,"total_items":name == "initial" ? 52000 : 5000,"total_pages":520]]))
            }
            try await preferences.refresh(connection)
            XCTAssertTrue(preferences.refreshVerifiesConnection("featherless")); XCTAssertEqual(preferences.modelCount(connection), 52000)
            let first = try await preferences.searchModels(connection, operation: .textEditing, query: "Qwen")
            let second = try await preferences.searchModels(connection, operation: .textEditing, query: "Qwen", cursor: first.nextCursor)
            XCTAssertEqual(second.models.first?.id, "Qwen/2")
            XCTAssertEqual(preferences.modelCount(connection), 52000, "a filtered search must not shrink the provider count")
            XCTAssertNil(preferences.selection(.textEditing), "search never selects a paid model")
            try preferences.select(.init(connectionID: connection.id, modelID: "Qwen/2"), for: .textEditing)
            XCTAssertEqual(preferences.selection(.textEditing)?.modelID, "Qwen/2")
            XCTAssertEqual(paths, ["/v1/plan", "/v1/models", "/v1/models", "/v1/models"])
        }
    }
    func testOpenRouterSearchCachesWholeCatalogButBoundsPersistenceAndKeepsChosenModel() async throws {
        try await fixture { preferences in
            let connection = AIConnection(provider: "openrouter", name: "Router", endpoint: URL(string: "https://openrouter.ai/api/v1")!)
            try preferences.add(connection, key: "synthetic")
            var network = 0
            CatalogHTTP.respond = { request in
                network += 1
                if request.url!.path.hasSuffix("/key") { return (200, Data(#"{"data":{"label":"fixture"}}"#.utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: ["data":(0..<1500).map { ["id":"vendor/model-\($0)"] }]))
            }
            let page = try await preferences.searchModels(connection, operation: .textEditing, query: "model-1499")
            XCTAssertEqual(page.models.map(\.id), ["vendor/model-1499"])
            _ = try await preferences.searchModels(connection, operation: .textEditing, query: "model-1498")
            XCTAssertEqual(network, 2, "one authenticated check and one catalog, no network per keystroke")
            XCTAssertEqual(preferences.modelCount(connection), 1500)
            XCTAssertLessThanOrEqual(preferences.catalogs[connection.id.uuidString]!.count, 1000)
            try preferences.select(.init(connectionID: connection.id, modelID: "vendor/model-1499"), for: .textEditing)
            XCTAssertTrue(preferences.catalogs[connection.id.uuidString]!.contains { $0.id == "vendor/model-1499" })
            XCTAssertLessThanOrEqual(preferences.catalogs[connection.id.uuidString]!.count, 1000)
        }
    }
    func testEditingConnectionCannotSendItsReplacementKeyToThePreviousEndpoint() async throws {
        try await fixture { preferences in
            let original = AIConnection(provider: "openaiCompatible", name: "Compatible", endpoint: URL(string: "https://previous.example/v1")!)
            try preferences.add(original, key: "synthetic-previous-key")
            let running = try preferences.textProvider(original)
            var edited = original; edited.endpoint = URL(string: "https://replacement.example/v1")!
            try preferences.update(edited, key: "synthetic-replacement-key")
            CatalogHTTP.respond = { request in
                XCTAssertEqual(request.url?.host, "previous.example")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-previous-key", "a request retains its endpoint/key pair")
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Original."}}]}"#.utf8))
            }
            let output = try await running.generate(.init(model: "fixture", instructions: "Correct.", text: "Original"))
            XCTAssertEqual(output, "Original.")
            let next = try preferences.textProvider(edited)
            CatalogHTTP.respond = { request in
                XCTAssertEqual(request.url?.host, "replacement.example")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-replacement-key")
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Next."}}]}"#.utf8))
            }
            _ = try await next.generate(.init(model: "fixture", instructions: "Correct.", text: "Next"))
        }
    }
    func testCompatibleProviderIsSearchableBeforeAnyCatalogWasCached() async throws {
        try await fixture { preferences in
            let connection = AIConnection(provider: "featherless", name: "Featherless", endpoint: URL(string: "https://api.featherless.ai/v1")!)
            try preferences.add(connection, key: "synthetic")
            XCTAssertNil(preferences.catalogs[connection.id.uuidString])
            XCTAssertTrue(preferences.supports(.textEditing, connection: connection))
            XCTAssertTrue(preferences.supports(.translation, connection: connection))
            XCTAssertFalse(preferences.supports(.transcription, connection: connection))
            XCTAssertNil(preferences.selection(.textEditing))
        }
    }
    func testUnavailableModelCannotBecomePaidSelection() async throws {
        try await fixture { preferences in
            let connection = AIConnection(provider: "openaiCompatible", name: "Compatible", endpoint: URL(string: "https://compatible.example/v1")!)
            try preferences.add(connection, key: "synthetic")
            CatalogHTTP.respond = { _ in (200, Data(#"{"data":[{"id":"vendor/model","available_on_current_plan":false}]}"#.utf8)) }
            try await preferences.refresh(connection)
            XCTAssertThrowsError(try preferences.select(.init(connectionID: connection.id, modelID: "vendor/model"), for: .textEditing))
            XCTAssertNil(preferences.selection(.textEditing))
            XCTAssertFalse(preferences.refreshVerifiesConnection("openaiCompatible"))
        }
    }
    func testTranslationCapturesSettingsAndTheNextTranslationUsesUpdatedOnes() async throws {
        try await fixture { preferences in
            let connection = AIConnection(provider: "openrouter", name: "Router", endpoint: URL(string: "https://router.example/v1")!)
            try preferences.add(connection, key: "synthetic")
            CatalogHTTP.respond = { request in
                if request.url!.path.hasSuffix("/key") { return (200, Data(#"{"data":{"label":"fixture"}}"#.utf8)) }
                return (200, Data(#"{"data":[{"id":"model","reasoning":{"supported_efforts":["low","high"],"mandatory":true}}]}"#.utf8))
            }
            try await preferences.refresh(connection)
            try preferences.select(.init(connectionID: connection.id, modelID: "model", options: .init(reasoningEffort: .low,
                routing: .init(only: ["groq"], allowFallbacks: false))), for: .translation)
            let running = try preferences.translationProvider(preferences.selection(.translation)!)
            try preferences.setTextOptions(.init(reasoningEffort: .high, routing: .init(only: ["cerebras"])), for: .translation)
            var efforts: [String] = [], servers: [[String]] = []
            CatalogHTTP.respond = { request in
                let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                    stream.open(); defer { stream.close() }; var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; result.append(contentsOf: bytes.prefix(n)) }
                    return result
                } ?? Data()
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                efforts.append(try XCTUnwrap((body["reasoning"] as? [String: Any])?["effort"] as? String))
                servers.append(try XCTUnwrap((body["provider"] as? [String: Any])?["only"] as? [String]))
                return (200, Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"Translated."}}]}"#.utf8))
            }
            _ = try await running.translate("Original.", from: "en", to: "ru", model: "model")
            _ = try await preferences.translationProvider(preferences.selection(.translation)!).translate("Next.", from: "en", to: "ru", model: "model")
            XCTAssertEqual(efforts, ["low", "high"])
            XCTAssertEqual(servers, [["groq"], ["cerebras"]])
        }
    }
}
