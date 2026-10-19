import Foundation
import Observation

public protocol TextTranslationEngine: Sendable {
    func setQuality(_ quality: ProcessingQuality) async
    func availableQualities(from: String, to: String) -> [ProcessingQuality]
    func prepare(from: String, to: String, onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws
    func translate(_ text: String, from: String, to: String) async throws -> String
    var residentModelCount: Int { get async }
    func unload() async
}

public extension TextTranslationEngine {
    func setQuality(_ quality: ProcessingQuality) async {}
    func availableQualities(from: String, to: String) -> [ProcessingQuality] { [.quality] }
}

/// Owns an editable translation independently of dictation, notes and microphone state.
@MainActor @Observable public final class TextTranslationModel {
    public enum Phase { case idle, preparing, translating, cancelling }
    public static let characterLimit = 10_000
    public let maximumCharacters: Int
    public var inputCharacters: Int { input.unicodeScalars.count }
    public var input = "" { didSet { if oldValue != input { invalidate() } } }
    public private(set) var source: String
    public private(set) var target: String
    public private(set) var quality = ProcessingQuality.quality
    public private(set) var output = ""
    public private(set) var error: String?
    public private(set) var phase = Phase.idle
    public private(set) var fraction: Double?
    public private(set) var modelsLoaded = false
    @ObservationIgnored private let engine: any TextTranslationEngine
    @ObservationIgnored private let targets: @MainActor (String) -> [String]
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(engine: any TextTranslationEngine, source: String, target: String,
                availableTargets: @escaping @MainActor (String) -> [String], maximumCharacters: Int = characterLimit) {
        self.maximumCharacters = maximumCharacters
        self.engine = engine; self.source = source; self.targets = availableTargets
        let options = availableTargets(source)
        self.target = options.contains(target) ? target : options.first ?? target
    }
    public var availableQualities: [ProcessingQuality] { engine.availableQualities(from: source, to: target) }
    public func setQuality(_ value: ProcessingQuality) {
        guard !isBusy, availableQualities.contains(value), quality != value else { return }
        quality = value; invalidate()
    }
    private func validateQuality() { if !availableQualities.contains(quality) { quality = .quality } }
    public var isBusy: Bool { phase != .idle }
    public var availableTargets: [String] { targets(source) }
    public var canTranslate: Bool { !isBusy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && inputCharacters <= maximumCharacters && availableTargets.contains(target) }
    public var canSwap: Bool { !isBusy && targets(target).contains(source) }
    public func setSource(_ value: String) {
        guard !isBusy, value != source else { return }
        source = value
        if !availableTargets.contains(target) { target = availableTargets.first ?? target }
        validateQuality(); invalidate()
    }
    public func setTarget(_ value: String) {
        guard !isBusy, availableTargets.contains(value), value != target else { return }
        target = value; validateQuality(); invalidate()
    }
    public func swap() {
        guard canSwap else { return }
        let translated = output, oldSource = source
        source = target; target = oldSource
        if !translated.isEmpty { input = translated }
        validateQuality(); invalidate()
    }
    private func invalidate() {
        generation = UUID(); output = ""; error = nil; cancel()
    }
    public func cancel() {
        guard isBusy else { return }
        phase = .cancelling; work?.cancel()
    }
    @discardableResult public func start() -> Task<Void, Never>? {
        guard canTranslate else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines), from = source, to = target
        let chosenQuality = quality
        let token = UUID(); generation = token
        output = ""; error = nil; fraction = nil; phase = .preparing
        let task = Task {
            var succeeded = false
            do {
                await engine.setQuality(chosenQuality)
                try await engine.prepare(from: from, to: to) { [weak self] value in
                    guard let self, self.generation == token, self.phase == .preparing else { return }
                    self.fraction = min(1, max(0, value))
                }
                try Task.checkCancellation()
                phase = .translating; fraction = nil
                let result = try await engine.translate(text, from: from, to: to)
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderValueNotFound) }
                output = result; succeeded = true
            } catch {
                if !Task.isCancelled, generation == token { self.error = error.localizedDescription }
            }
            if !succeeded { await engine.unload() }
            modelsLoaded = await engine.residentModelCount > 0
            fraction = nil; phase = .idle; work = nil
        }
        work = task
        return task
    }
    public func unload() async {
        guard !isBusy else { return }
        await engine.unload(); modelsLoaded = false
    }
}
