import XCTest
import MurmurCore
@testable import MurmurTranslation

final class TranslationProfileTests: XCTestCase {
    func testEveryBaselineDirectionHasOneDeterministicDownloadAndExecutionRoute() throws {
        let service = TranslationService(modelsRoot: URL(fileURLWithPath: "/nonexistent-profile-tests"))
        var count = 0
        for source in LanguagePair.qualityLanguages {
            for target in LanguagePair.qualityLanguages where source != target {
                let profile = try XCTUnwrap(service.qualityProfile(from: source, to: target))
                XCTAssertEqual(profile.qualification, .baseline)
                XCTAssertEqual(profile.route, service.qualityRoute(from: source, to: target))
                XCTAssertEqual(profile.route, service.qualityDownloadRoute(from: source, to: target))
                XCTAssertTrue(profile.models.allSatisfy { TranslationDownloader.hasQualityDownload(for: $0.pair) })
                count += 1
            }
        }
        XCTAssertEqual(count, 1122)
        XCTAssertEqual(TranslationProfileCatalog.baseline.bindings.count, 68)
        XCTAssertEqual(Set(TranslationProfileCatalog.baseline.bindings.values.map(\.modelID)).count, 47)
    }

    func testUnqualifiedInstalledDirectoryCannotChangeSelectedRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ct2-defr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["model.bin", "source.spm", "target.spm", "config.json"] {
            try Data("unqualified".utf8).write(to: directory.appendingPathComponent(name))
        }
        let service = TranslationService(modelsRoot: root)
        XCTAssertEqual(service.qualityRoute(from: "de", to: "fr"),
                       .pivot(.init(source: "de", target: "en"), .init(source: "en", target: "fr")))
    }

    func testQualifiedOverrideRequiresExplicitRolloutAndExactScenarioDevice() throws {
        let baseline = TranslationProfileCatalog.baseline
        let original = try XCTUnwrap(baseline.bindings[.init(source: "ru", target: "en")])
        let tuned = TranslationModelBinding(pair: original.pair, modelID: original.modelID,
            directoryName: original.directoryName, targetTag: original.targetTag, decoding: .init(beamSize: 4))
        let request = TranslationProfileRequest(source: "ru", target: "en", scenario: .text, device: .iPhone15Pro)
        let profile = TranslationProfile(catalogVersion: "test", request: request, models: [tuned],
                                         qualification: .qualified, evidenceID: "test-only-evidence")
        let off = try TranslationProfileCatalog(version: "test", bindings: Array(baseline.bindings.values),
            additionalModels: [tuned], qualifiedProfiles: [profile])
        let on = try TranslationProfileCatalog(version: "test", bindings: Array(baseline.bindings.values),
            additionalModels: [tuned], qualifiedProfiles: [profile], enableQualifiedProfiles: true)
        XCTAssertEqual(off.resolve(request)?.models.first?.decoding.beamSize, 1)
        XCTAssertEqual(on.resolve(request)?.models.first?.decoding.beamSize, 4)
        XCTAssertEqual(on.resolve(.init(source: "ru", target: "en", scenario: .page, device: .iPhone15Pro))?.qualification, .baseline)
        XCTAssertEqual(on.resolve(.init(source: "ru", target: "en", scenario: .text, device: .other))?.qualification, .baseline)
    }

    func testMalformedOrUnregisteredProfilesFailClosed() throws {
        let bindings = Array(TranslationProfileCatalog.baseline.bindings.values)
        let model = try XCTUnwrap(bindings.first)
        let request = TranslationProfileRequest(source: model.pair.source, target: model.pair.target)
        XCTAssertThrowsError(try TranslationProfileCatalog(version: "x", bindings: bindings + [model]))
        XCTAssertThrowsError(try TranslationProfileCatalog(version: "x", bindings: bindings,
            qualifiedProfiles: [.init(catalogVersion: "x", request: request, models: [model], qualification: .qualified)]))
        let escaped = TranslationModelBinding(pair: model.pair, modelID: "test", directoryName: "../outside")
        XCTAssertThrowsError(try TranslationProfileCatalog(version: "x", bindings: [escaped]))
        let disconnected = TranslationProfile(catalogVersion: "x", request: .init(source: "ru", target: "fi"),
            models: [model], qualification: .qualified, evidenceID: "test-only")
        XCTAssertThrowsError(try TranslationProfileCatalog(version: "x", bindings: bindings, qualifiedProfiles: [disconnected]))
    }

    /// The incomplete pivot (fi-en + en-ru offers no fi -> ru) is covered by
    /// `PreparationAndLanguageTests` in MurmurCore.
    func testOfflineAvailabilityRequiresSelectedModelsNotAnyPossiblePivot() {
        let complete = OfflineTranslationRoutes(pairs: [.init(source: "fi", target: "ru")])
        XCTAssertEqual(complete.targets(from: "fi"), ["ru"])
    }

    func testMissingDirectModelDoesNotSilentlyExecutePivot() async throws {
        let service = TranslationService(modelsRoot: URL(fileURLWithPath: "/nonexistent-profile-test"))
        do {
            _ = try await service.translateQuality("Hei", from: "fi", to: "ru")
            XCTFail("Missing selected model should fail")
        } catch let error as TranslationService.QualityUnavailable {
            XCTAssertEqual(error.pair, .init(source: "fi", target: "ru"))
        }
    }

    func testWhitespaceOnlyDocumentIsPreservedWithoutLoadingModels() async throws {
        let service = TranslationService(modelsRoot: URL(fileURLWithPath: "/nonexistent-profile-test"), scenario: .text)
        let result = try await service.translateQuality("  \r\n\n", from: "ru", to: "en")
        XCTAssertEqual(result.text, "  \r\n\n")
        XCTAssertEqual(result.passes.count, 0)
    }

    func testGroupBindingsShareLoadedWeightsWithoutTargetBleed() async throws {
        guard let path = ProcessInfo.processInfo.environment["MURMUR_EU_NATIVE_ROOT"] else {
            throw XCTSkip("Verified local European OPUS packs required")
        }
        let service = TranslationService(modelsRoot: URL(fileURLWithPath: path))
        let source = "I will send the documents tomorrow."
        let danish = try await service.translateQuality(source, from: "en", to: "da")
        let swedish = try await service.translateQuality(source, from: "en", to: "sv")
        let repeated = try await service.translateQuality(source, from: "en", to: "da")
        XCTAssertEqual(danish.text, repeated.text)
        XCTAssertNotEqual(danish.text, swedish.text)
        XCTAssertEqual(danish.passes.first?.modelID, swedish.passes.first?.modelID)
        let loads = await service.qualityModelLoadCount
        XCTAssertEqual(loads, 1, "Shared weights should survive switching the target tag")
        await service.evictAll()
        let resident = await service.residentModelCount
        XCTAssertEqual(resident, 0)
    }
}
