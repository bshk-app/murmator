import Foundation
import MurmurCore

/// Continuous preview and strict OPUS correction, independent of the app UI.
public actor TranslationSession {
    typealias Translate = @Sendable (String, String, String) async throws -> String
    private var selectedQuality = ProcessingQuality.quality
    private let fast: TranslationService
    private let quality: TranslationService
    private let fastTranslation: Translate
    private let qualityTranslation: Translate
    private let modelsRoot: URL
    private var generation = UUID()
    private var pair: LanguagePair?
    private var snapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
    private var previews: [UInt64: (String, String)] = [:]
    private var corrections: [UInt64: (String, String)] = [:]
    private var requested: [UInt64: String] = [:]
    private var failed: Set<UInt64> = []
    private var draft = ""
    private var previewTask: Task<Void, Never>?
    private var jobs: [UInt64: Task<Void, Never>] = [:]
    private var lastPreview = Date.distantPast
    private var onUpdate: (@Sendable (String) -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var onSegments: (@Sendable ([UtteranceTranslation]) -> Void)?
    private var finishing = false

    public init(modelsRoot: URL, qualityModelsRoots: [URL] = [],
                profileCatalog: TranslationProfileCatalog = .current, device: TranslationDeviceClass = .current,
                assetRegistry: QualityModelAssetRegistry = .current) {
        self.init(modelsRoot: modelsRoot, qualityModelsRoots: qualityModelsRoots,
                  profileCatalog: profileCatalog, device: device, assetRegistry: assetRegistry,
                  fastTranslation: nil, qualityTranslation: nil)
    }

    init(modelsRoot: URL, qualityModelsRoots: [URL] = [],
         profileCatalog: TranslationProfileCatalog = .current, device: TranslationDeviceClass = .current,
         assetRegistry: QualityModelAssetRegistry = .current,
         fastTranslation: Translate?, qualityTranslation: Translate?) {
        self.modelsRoot = modelsRoot
        let fast = TranslationService(modelsRoot: modelsRoot)
        let quality = TranslationService(modelsRoot: modelsRoot, qualityModelsRoots: qualityModelsRoots,
                                     profileCatalog: profileCatalog, scenario: .dictation, device: device, assetRegistry: assetRegistry)
        self.fast = fast
        self.quality = quality
        self.fastTranslation = fastTranslation ?? { try await fast.translate($0, from: $1, to: $2) }
        self.qualityTranslation = qualityTranslation ?? { try await quality.translateQuality($0, from: $1, to: $2).text }
    }
    public func prepare(from: String, to: String, priority: ProcessingQuality = .quality, onProgress: @escaping @MainActor @Sendable (TranslationDownloader.Progress) -> Void = { _ in }) async throws {
        if selectedQuality != priority { cancel() }
        selectedQuality = priority
        guard from != to else { return }
        if priority == .fast {
            guard let route = fast.route(from: from, to: to) else { throw TranslationService.Unsupported(source: from, target: to) }
            let legs: [LanguagePair]
            switch route { case .direct(let pair): legs = [pair]; case .pivot(let a, let b): legs = [a, b] }
            for (index, leg) in legs.enumerated() {
                try Task.checkCancellation()
                try await TranslationDownloader.download(pair: leg, into: modelsRoot, kind: .fast) { value in
                    var progress = value
                    progress.fraction = (Double(index) + value.fraction) / Double(legs.count)
                    onProgress(progress)
                }
            }
            try await fast.prepare(from: from, to: to)
            return
        }
        let fastRoute = fast.route(from: from, to: to)
        func legs(_ route: LanguagePair.Route) -> [LanguagePair] {
            switch route { case .direct(let p): return [p]; case .pivot(let a, let b): return [a,b] }
        }
        // Validate the strict route before spending time or data on previews.
        try quality.validateQualityPreparation(from: from, to: to)
        let downloads = fastRoute.map(legs) ?? []
        let qualityBytes = quality.pendingQualityDownloadBytes(from: from, to: to)
        let weights = downloads.map { TranslationDownloader.expectedDownloadBytes(for: $0, kind: .fast) ?? 1 }
        let total = max(1, qualityBytes + weights.reduce(0, +))
        try await quality.prepareQuality(from: from, to: to) { value in
            var progress = value
            progress.totalBytes = total
            progress.receivedBytes = Int64(Double(qualityBytes) * value.fraction)
            progress.fraction = Double(progress.receivedBytes) / Double(total)
            onProgress(progress)
        }
        var completed = qualityBytes
        for (index, download) in downloads.enumerated() {
            try Task.checkCancellation()
            let base = completed, weight = weights[index]
            _ = try await TranslationDownloader.download(pair: download, into: modelsRoot, kind: .fast) { progress in
                var aggregate = progress
                aggregate.totalBytes = total
                aggregate.receivedBytes = base + Int64(Double(weight) * progress.fraction)
                aggregate.fraction = Double(aggregate.receivedBytes) / Double(total)
                onProgress(aggregate)
            }
            completed += weight
            var aggregate = TranslationDownloader.Progress()
            aggregate.totalBytes = total; aggregate.receivedBytes = completed
            aggregate.fraction = Double(completed) / Double(total)
            await onProgress(aggregate)
        }
        if fastRoute != nil { try await fast.prepare(from: from, to: to) }
        var done = TranslationDownloader.Progress()
        done.fraction = 1; done.totalBytes = total; done.receivedBytes = total
        await onProgress(done)
    }
    /// Warm both engines using synthetic punctuation; never publishes this output.
    public func warmUp(from: String, to: String) async throws {
        guard from != to else { return }
        if fast.route(from: from, to: to) != nil { _ = try await fast.translate(".", from: from, to: to) }
        try Task.checkCancellation()
        if selectedQuality == .quality { _ = try await quality.translateQuality(".", from: from, to: to) }
    }

    public func update(_ value: CaptionSnapshot, from: String, to: String,
                       onUpdate: @escaping @Sendable (String) -> Void,
                       onFailure: @escaping @Sendable (String) -> Void,
                       onSegments: @escaping @Sendable ([UtteranceTranslation]) -> Void = { _ in }) {
        guard !finishing else { return }
        guard from != to else { cancel(); onUpdate((value.confirmed.map(\.text)+[value.provisional]).joined(separator:" ")); return }
        let nextPair = LanguagePair(source: from, target: to)
        if pair != nextPair { cancel(); pair = nextPair }
        guard value.revision >= snapshot.revision else { return }
        snapshot = value; self.onUpdate = onUpdate; self.onFailure = onFailure; self.onSegments = onSegments
        let retained = Set(value.confirmed.map(\.id))
        for id in Set(requested.keys).union(failed) where !retained.contains(id) {
            jobs.removeValue(forKey: id)?.cancel(); requested[id]=nil; corrections[id]=nil; previews[id]=nil
            failed.remove(id)
        }
        let token = generation
        for phrase in value.confirmed where phrase.state == .confirmed && !phrase.text.isEmpty && requested[phrase.id] != phrase.text {
            requested[phrase.id] = phrase.text; jobs[phrase.id]?.cancel()
            failed.remove(phrase.id)
            jobs[phrase.id] = Task {
                do {
                    let result = try await finalTranslation(phrase.text, from: from, to: to)
                    guard !Task.isCancelled, generation == token, requested[phrase.id] == phrase.text else { return }
                    corrections[phrase.id]=(phrase.text,result); jobs[phrase.id]=nil; render()
                } catch {
                    guard generation == token, !Task.isCancelled, requested[phrase.id] == phrase.text else { return }
                    // A missing model or another transient error is not a
                    // completed translation. Retry on the next snapshot.
                    requested[phrase.id] = nil
                    jobs[phrase.id] = nil
                    failed.insert(phrase.id)
                    onFailure(error.localizedDescription)
                    render()
                }
            }
        }
        if previewTask == nil, Date().timeIntervalSince(lastPreview) >= 0.5 {
            lastPreview = Date()
            previewTask = Task {
                defer { if generation == token { previewTask = nil } }
                do {
                    for phrase in value.confirmed where previews[phrase.id]?.0 != phrase.text {
                        let translated = try await preview(phrase.text, from: from, to: to)
                        guard !Task.isCancelled, generation == token else { return }
                        if snapshot.confirmed.contains(where: { $0.id == phrase.id && $0.text == phrase.text }) { previews[phrase.id]=(phrase.text,translated) }
                    }
                    let translated = try await preview(value.provisional, from: from, to: to)
                    guard !Task.isCancelled, generation == token, snapshot.revision == value.revision else { return }
                    draft=translated; render()
                } catch { if generation == token && !Task.isCancelled { onFailure(error.localizedDescription) } }
            }
        }
        render()
    }
    /// Mozilla where available; otherwise the prepared OPUS route also supplies
    /// previews. Lack of a Mozilla pack must not disable an OPUS language.
    public func preview(_ text: String, from: String, to: String) async throws -> String {
        if fast.route(from: from, to: to) != nil { return try await fastTranslation(text, from, to) }
        return try await finalTranslation(text, from: from, to: to)
    }
    public func finish(_ text: String, from: String, to: String) async throws -> String {
        cancel()
        finishing = true; let token = generation
        defer { if generation == token { finishing = false } }
        let result = try await finalTranslation(text, from: from, to: to)
        guard generation == token else { throw CancellationError() }
        return result
    }
    public func finishUtterances(_ utterances: [RecordedUtterance], from: String, to: String,
                                 onSegment: @escaping @Sendable (UtteranceTranslation) async -> Void) async throws {
        let saved = pair == LanguagePair(source: from, target: to) ? corrections : [:]
        cancel()
        finishing = true; let token = generation
        defer { if generation == token { finishing = false } }
        var failure: Error?
        for utterance in utterances where !utterance.text.isEmpty {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            do {
            let translated: String
            if from == to { translated = utterance.text }
            else if let cached = saved[utterance.id], cached.0 == utterance.text { translated = cached.1 }
            else { translated = try await finalTranslation(utterance.text, from: from, to: to) }
            guard generation == token else { throw CancellationError() }
            await onSegment(.init(id: utterance.id, source: utterance.text, text: translated, isFinal: true))
            } catch {
                if Task.isCancelled || generation != token { throw CancellationError() }
                failure = error
                await onSegment(.init(id: utterance.id, source: utterance.text, text: "", isFinal: true, failed: true))
            }
        }
        if let failure { throw failure }
    }
    private func finalTranslation(_ text: String, from: String, to: String) async throws -> String {
        if selectedQuality == .fast { return try await fastTranslation(text, from, to) }
        return try await qualityTranslation(text, from, to)
    }
    public func cancel() {

        finishing = false
        generation=UUID(); previewTask?.cancel(); previewTask=nil
        for job in jobs.values { job.cancel() }; jobs.removeAll()
        requested.removeAll(); corrections.removeAll(); previews.removeAll(); failed.removeAll(); draft=""; pair=nil
        snapshot = CaptionSnapshot(revision: 0, confirmed: [], provisional: "")
    }
    public var residentModelCount: Int {
        get async {
            let previewCount = await fast.residentModelCount
            let qualityCount = await quality.residentModelCount
            return previewCount + qualityCount
        }
    }
    public func unload() async {
        cancel()
        await fast.evictAll()
        await quality.evictAll()
    }
    private func render() {
        let segments = snapshot.confirmed.compactMap { phrase -> UtteranceTranslation? in
            if let value = corrections[phrase.id], value.0 == phrase.text { return .init(id: phrase.id, source: phrase.text, text: value.1, isFinal: true) }
            if failed.contains(phrase.id) { return .init(id: phrase.id, source: phrase.text, text: "", isFinal: true, failed: true) }
            if let value = previews[phrase.id], value.0 == phrase.text { return .init(id: phrase.id, source: phrase.text, text: value.1, isFinal: false) }
            return nil
        }
        onSegments?(segments + (snapshot.provisional.isEmpty ? [] : [.init(id: .max, source: snapshot.provisional, text: draft, isFinal: false)]))
        let text = snapshot.confirmed.compactMap { phrase -> String? in
            if let value=corrections[phrase.id], value.0==phrase.text { return value.1 }
            if let value=previews[phrase.id], value.0==phrase.text { return value.1 }
            return nil
        } + (snapshot.provisional.isEmpty ? [] : [draft])
        onUpdate?(text.filter { !$0.isEmpty }.joined(separator:" "))
    }
}
