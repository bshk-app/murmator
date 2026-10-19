import Foundation
import XCTest
import MurmurCloud
@testable import Murmur

/// Models: the provider first, then only its models; nothing cloud is chosen
/// for the user, and a saved model is never dropped because a list is missing.
/// Providers: honest check states and what a delete takes with it.
@MainActor
final class ProviderSettingsTests: XCTestCase {
    private let suite = "ProviderSettingsTests"
    private let dictator = AIConnection(provider: "dictator", name: "Dictator (work)", endpoint: URL(string: "https://dictator.example/v1")!)
    private let openAI = AIConnection(provider: "openai", name: "OpenAI (personal)", endpoint: URL(string: "https://api.openai.com/v1")!)
    private let unchecked = AIConnection(provider: "anthropic", name: "Anthropic", endpoint: URL(string: "https://api.anthropic.com/v1")!)

    override func tearDown() {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A store read from defaults, so no key ever touches the Keychain.
    private func preferences(selections: [String: AISelection] = [:], extra: [AIConnection] = []) throws -> ProviderPreferences {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let catalogs: [String: [AIModel]] = [
            dictator.id.uuidString: [.init(id: "whisper-large-v3", name: "Whisper large v3", kind: .speech, operations: [.transcription])],
            openAI.id.uuidString: [.init(id: "gpt-a", name: "GPT A", kind: .text, operations: [.textEditing, .translation]),
                                   .init(id: "gpt-b", name: "GPT B", kind: .text, operations: [.textEditing])],
        ]
        defaults.set(try JSONEncoder().encode([dictator, openAI, unchecked] + extra), forKey: "ai.connections.v1")
        defaults.set(try JSONEncoder().encode(catalogs), forKey: "ai.catalogs.v1")
        defaults.set(try JSONEncoder().encode(selections), forKey: "ai.selections.v1")
        return ProviderPreferences(defaults: defaults, vault: .init(service: "app.bshk.murmur.tests.\(UUID())"))
    }

    /// Offered by what a connection can do, not by what its kept list happens to hold.
    func testProvidersThatCanDoTheStepAreOfferedEvenWithAnEmptyList() throws {
        let deepgram = AIConnection(provider: "deepgram", name: "Deepgram", endpoint: URL(string: "https://api.deepgram.com/v1")!)
        let prefs = try preferences(extra: [deepgram])
        let correctors = ProviderModelChoice.providers(for: .textEditing, in: prefs).map(\.id)
        XCTAssertTrue(correctors.contains(unchecked.id), "an Anthropic connection with no list yet can still correct text")
        XCTAssertTrue(correctors.contains(openAI.id))
        XCTAssertFalse(correctors.contains(deepgram.id), "speech-only connections are not offered for the corrector")
        for id in correctors {
            XCTAssertTrue(prefs.supports(.textEditing, connection: prefs.connections.first { $0.id == id }!))
        }
        XCTAssertEqual(ProviderModelChoice.models(for: .textEditing, of: openAI, in: prefs).map(\.id), ["gpt-a", "gpt-b"])
        XCTAssertEqual(ProviderModelChoice.models(for: .translation, of: openAI, in: prefs).map(\.id), ["gpt-a"])
    }

    func testPickingAProviderChangesNothingUntilAModelIsChosen() throws {
        let prefs = try preferences()
        let shown = ProviderModelChoice.displayed(.textEditing, draft: openAI.id, in: prefs)
        XCTAssertEqual(shown.provider, openAI.id.uuidString)
        XCTAssertEqual(shown.model, ProviderModelChoice.noModelTag, "no model is picked on the user's behalf")
        XCTAssertNil(prefs.selection(.textEditing), "the step stays Local until a model is chosen")

        try ProviderModelChoice.choose("gpt-b", of: openAI.id, for: .textEditing, in: prefs)
        XCTAssertEqual(prefs.selection(.textEditing), .init(connectionID: openAI.id, modelID: "gpt-b"))
        XCTAssertEqual(ProviderModelChoice.displayed(.textEditing, draft: openAI.id, in: prefs).model, "gpt-b")

        try ProviderModelChoice.chooseLocal(for: .textEditing, in: prefs)
        XCTAssertNil(prefs.selection(.textEditing))
        XCTAssertEqual(ProviderModelChoice.displayed(.textEditing, draft: nil, in: prefs).provider, ProviderModelChoice.localTag)
    }

    func testADraftForADeletedConnectionShowsTheSavedChoiceAgain() throws {
        let saved = AISelection(connectionID: openAI.id, modelID: "gpt-a")
        let prefs = try preferences(selections: [AIOperation.translation.rawValue: saved])
        let gone = UUID()
        XCTAssertEqual(ProviderModelChoice.displayed(.translation, draft: gone, in: prefs).provider, openAI.id.uuidString)
        XCTAssertEqual(ProviderModelChoice.displayed(.translation, draft: gone, in: prefs).model, "gpt-a")
        XCTAssertEqual(prefs.selection(.translation), saved)
    }

    func testADraftForAConnectionThatCannotDoTheStepIsIgnored() throws {
        let deepgram = AIConnection(provider: "deepgram", name: "Deepgram", endpoint: URL(string: "https://api.deepgram.com/v1")!)
        let saved = AISelection(connectionID: openAI.id, modelID: "gpt-a")
        let prefs = try preferences(selections: [AIOperation.textEditing.rawValue: saved], extra: [deepgram])
        XCTAssertEqual(ProviderModelChoice.displayed(.textEditing, draft: deepgram.id, in: prefs).provider, openAI.id.uuidString,
                       "an incompatible draft must not show Local controls over a saved cloud choice")
        XCTAssertEqual(prefs.selection(.textEditing), saved)
    }

    /// A text provider whose list was reset (as after a migration) is still a valid draft:
    /// the search shows its real models or its real error. Nothing is chosen for the user.
    func testADraftWithAnEmptyListIsKeptButChoosesNothing() throws {
        let saved = AISelection(connectionID: openAI.id, modelID: "gpt-a")
        let prefs = try preferences(selections: [AIOperation.textEditing.rawValue: saved])
        let shown = ProviderModelChoice.displayed(.textEditing, draft: unchecked.id, in: prefs)
        XCTAssertEqual(shown.provider, unchecked.id.uuidString)
        XCTAssertEqual(shown.model, ProviderModelChoice.noModelTag)
        XCTAssertEqual(prefs.selection(.textEditing), saved)
    }

    func testAModelTheStepCannotUseIsRefused() throws {
        let prefs = try preferences()
        XCTAssertThrowsError(try ProviderModelChoice.choose("whisper-large-v3", of: dictator.id, for: .textEditing, in: prefs))
        XCTAssertNil(prefs.selection(.textEditing))
    }

    func testASavedModelOutsideTheLastListStaysChosen() throws {
        let saved = AISelection(connectionID: openAI.id, modelID: "gpt-5.6-terra")
        let prefs = try preferences(selections: [AIOperation.textEditing.rawValue: saved])
        XCTAssertTrue(ProviderModelChoice.savedModelIsMissing(.textEditing, in: prefs))
        XCTAssertEqual(ProviderModelChoice.displayed(.textEditing, draft: nil, in: prefs).model, "gpt-5.6-terra",
                       "shown by its saved id, not replaced")
        XCTAssertEqual(prefs.selection(.textEditing), saved)
    }

    func testTheChosenConnectionStaysOfferedWhileItsListIsEmpty() throws {
        let saved = AISelection(connectionID: unchecked.id, modelID: "claude-x")
        let prefs = try preferences(selections: [AIOperation.textEditing.rawValue: saved])
        XCTAssertTrue(ProviderModelChoice.providers(for: .textEditing, in: prefs).contains { $0.id == unchecked.id })
        XCTAssertEqual(ProviderModelChoice.displayed(.textEditing, draft: nil, in: prefs).provider, unchecked.id.uuidString)
    }

    func testDeleteNamesTheStepsThatFallBackToLocal() throws {
        let prefs = try preferences(selections: [
            AIOperation.textEditing.rawValue: .init(connectionID: openAI.id, modelID: "gpt-a"),
            AIOperation.translation.rawValue: .init(connectionID: openAI.id, modelID: "gpt-a"),
            AIOperation.transcription.rawValue: .init(connectionID: dictator.id, modelID: "whisper-large-v3"),
        ])
        XCTAssertEqual(ProviderModelChoice.stepsUsing(openAI.id, in: prefs), [.textEditing, .translation])
        XCTAssertEqual(ProviderModelChoice.stepsUsing(unchecked.id, in: prefs), [])
    }

    func testAFailedCheckShowsTheProvidersError() async {
        let checks = ProviderChecks(), id = UUID()
        await checks.check(id, verifies: true) { throw AIProviderError.refused(401) }
        guard case .failed(let message) = checks.states[id] else { return XCTFail("\(String(describing: checks.states[id]))") }
        XCTAssertEqual(message, AIProviderError.refused(401).localizedDescription, "the provider's error, not a generic one")
        XCTAssertEqual(ProviderChecks.summary(checks.states[id], savedModels: 6).tone, .error)
    }

    /// Deepgram's list is built in: listing it proves nothing about the key.
    func testABuiltInListIsNotReportedAsAVerifiedConnection() async throws {
        let deepgram = AIConnection(provider: "deepgram", name: "Deepgram", endpoint: URL(string: "https://api.deepgram.com/v1")!)
        let prefs = try preferences(extra: [deepgram])
        XCTAssertFalse(prefs.refreshVerifiesConnection(deepgram.provider))
        let checks = ProviderChecks()
        await checks.check(deepgram, in: prefs)
        XCTAssertEqual(checks.states[deepgram.id], .checked(models: prefs.modelCount(deepgram), verified: false))
        XCTAssertNotEqual(ProviderChecks.summary(checks.states[deepgram.id], savedModels: nil).tone, .ok)
        XCTAssertEqual(ProviderChecks.summary(.checked(models: 6, verified: true), savedModels: 6).tone, .ok)
        XCTAssertEqual(ProviderChecks.summary(nil, savedModels: 6).tone, .idle, "an earlier list is not a check now")
    }

    func testAnOlderCheckFinishingLaterDoesNotOverwriteTheNewerOne() async {
        let checks = ProviderChecks(), id = UUID()
        var first: CheckedContinuation<Int, Error>?
        let older = Task { await checks.check(id, verifies: true) { try await withCheckedThrowingContinuation { first = $0 } } }
        while first == nil { await Task.yield() }
        await checks.check(id, verifies: true) { 3 }   // after an edit
        XCTAssertEqual(checks.states[id], .checked(models: 3, verified: true))
        first?.resume(throwing: CancellationError())
        await older.value
        XCTAssertEqual(checks.states[id], .checked(models: 3, verified: true), "the stale check must not clear the new result")
    }

    func testDeletingDuringACheckLeavesNoStatusBehind() async {
        let checks = ProviderChecks(), id = UUID()
        var pending: CheckedContinuation<Int, Error>?
        let check = Task { await checks.check(id, verifies: true) { try await withCheckedThrowingContinuation { pending = $0 } } }
        while pending == nil { await Task.yield() }
        checks.forget(id)
        pending?.resume(returning: 5)
        await check.value
        XCTAssertNil(checks.states[id])
    }

    func testModelsHasItsOwnTabAndProvidersKeepsTheConnections() {
        XCTAssertTrue(SettingsTab.allCases.contains(.models))
        XCTAssertEqual(SettingsTab(request: "providers"), .providers)
        XCTAssertEqual(AIOperation.settingsOrder, [.streamingTranscription, .transcription, .textEditing, .translation])
    }
}
