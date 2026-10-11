import SwiftUI
import AVFoundation
import BackgroundTasks
import ActivityKit
import MurmurCore
import MurmurSpeech
import MurmurSession
import MurmurTranslation

@MainActor @Observable final class AppModel {
    enum Phase { case idle, preparing, ready, recording, refining }
    var phase = Phase.idle
    var pendingUtilityRoute: String?
    var photoTranslationActive = false
    var showSafariSetup = false
    func requestUtilityRoute(_ route: String) {
        guard !showRecorder else { error = L10n.text("Finish the current task to free memory."); return }
        pendingUtilityRoute = route
        if photoTranslationActive { return }
        if showSafariSetup {
            if route == "safari-setup" { pendingUtilityRoute = nil; return }
            showSafariSetup = false; return
        }
        if showAudioImport {
            if route == "audio-import" { pendingUtilityRoute = nil; return }
            if audioImports.busy { return }
            showAudioImport = false; return
        }
        if showKeyboardSetup { showKeyboardSetup = false; return }
        if showTranslation { showTranslation = false; return }
        if showLanguages { showLanguages = false; return }
        if showMemory { showMemory = false; return }
        if showStorage { showStorage = false; return }
        consumeUtilityRoute()
    }
    func consumeUtilityRoute() {
        guard !photoTranslationActive, let route = pendingUtilityRoute, !textTranslator.isBusy, !managingStorage, !showSafariSetup, !showKeyboardSetup, !showTranslation, !showLanguages, !showMemory, !showStorage, !showAudioImport else { return }
        pendingUtilityRoute = nil
        switch route {
        case "audio-import": showAudioImport = true
        case "keyboard": showKeyboardSetup = true; Task { await enableKeyboard() }
        case "settings": showSettings = true
        case "safari-setup": showSafariSetup = true
        case "languages": showLanguages = true
        // Widgets, Siri and the Action Button all land here. Each is an explicit
        // "record now", so the warm-up ends in capture, not in a button to tap.
        case "record": Task { await keyboard.stopAndEnd(); await start(immediately: true) }
        case "translate": Task { await keyboard.stopAndEnd(); showTranslation = true }
        case "storage": showStorage = true
        case "memory": showMemory = true
        case "release-memory": showMemory = true; Task { await releaseModels() }
        default: break
        }
    }
    let textTranslator = TextTranslationModel(
        engine: TextTranslationSession(modelsRoot: StoragePaths.translation),
        source: TranslationPreferences.source,
        target: TranslationPreferences.target,
        availableTargets: { TextTranslationSession.availableTargets(from: $0, modelsRoot: StoragePaths.translation) })
    func startTextTranslation() async {
        guard !busy, canReleaseMemory, textTranslator.canTranslate else { return }
        if speech != nil || directSpeech != nil || translationLoaded || keyboard.isActive { await releaseModels() }
        guard !busy else { return }
        let pack = TranslationLanguagePack(source: textTranslator.source, target: textTranslator.target)
        if let task = textTranslator.start() {
            publishWidgetState()
            await task.value
            if !textTranslator.output.isEmpty { languageLibrary.addTranslation(from: pack.source, to: pack.target) }
            publishWidgetState()
        }
    }
    let audioImports = AudioImportController()
    var showAudioImport = false
    func receiveAudio(_ url: URL) async {
        if !showRecorder { requestUtilityRoute("audio-import") }
        await audioImports.receive(url, language: source, model: speechModel)
    }
    func startAudioImport(_ id: UUID) async {
        if audioImports.activeID != nil { audioImports.start(id); return }
        guard canReleaseMemory else { return }
        await releaseModels()
        audioImports.start(id)
    }
    func openImport(for note: VoiceNote) { audioImports.selectedID = note.id; requestUtilityRoute("audio-import") }
    @ObservationIgnored private let watch = WatchSessionBridge()
    @ObservationIgnored private var drainingWatch = false
    init() {
        watch.onSessionReady = { [weak self] in self?.publishWatchContext() }
        watch.onRecordingStaged = { [weak self] in await self?.receiveWatchRecordings() }
        audioImports.onFinished = { [weak self] job in self?.reportTranscriptToWatch(job) }
        audioImports.onTiming = { [weak self] audio, decode, load in self?.learnSpeechTimings(audio, decode, load) }
        registerTranscriptionTask()
        watch.activate()
    }
    /// A recording made on the wrist answers back there, so the watch confirms the
    /// note exists without the user reaching for the phone.
    private func reportTranscriptToWatch(_ job: AudioImportJob) {
        guard job.origin == .watch, !job.text.isEmpty else { return }
        watch.send(transcript: job.text, for: job.filename)
        watch.announceCompletion(recording: job.filename)
    }
    /// Tells the watch which language the phone would recognise, and whether it can.
    func publishWatchContext() {
        watch.publish(languageName: AppLanguages.name(source), speechReady: languageLibrary.isPrepared("speech:" + source))
    }
    /// Hands every recording the watch delivered to the import, then transcribes
    /// what it may. Safe to call in the background: only the start is gated on
    /// being in front, and a recording the import refuses keeps its staged file
    /// for the next call.
    func receiveWatchRecordings() async {
        await requestWatchNotifications()
        guard !drainingWatch else { return }
        drainingWatch = true
        defer { drainingWatch = false }
        var attempted: Set<URL> = []
        var arrived = false
        while let url = WatchSessionBridge.stagedRecordings().first(where: { !attempted.contains($0) }) {
            attempted.insert(url)
            await receiveAudio(url)
            arrived = true
            if UIApplication.shared.applicationState == .active { await startWatchImport() }
        }
        guard UIApplication.shared.applicationState != .active else {
            await startWatchImport()
            return
        }
        // One banner, not two: either the note is being transcribed now and the
        // finish will say so, or it waits and the arrival says that instead.
        if !startWatchImportInBackground(), arrived {
            watch.announceArrival()
            // Too long for the wake, so ask the scheduler for a wider window.
            scheduleTranscriptionTask()
        }
    }
    // MARK: - Transcribing while the phone is put away

    /// A wake from the watch grants about fifteen seconds, and a cold model load
    /// alone takes fourteen of them. The scheduler is the only window wide enough,
    /// at the price of running on the system's timetable rather than ours.
    static let transcriptionTaskID = "app.bshk.murmur.ios.transcribe"

    private func registerTranscriptionTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.transcriptionTaskID, using: nil) { [weak self] task in
            Task { @MainActor in await self?.runScheduledTranscription(task) }
        }
    }

    /// Asked for whenever a recording is left waiting. Submitting the same
    /// identifier twice replaces the pending request rather than queueing another.
    func scheduleTranscriptionTask() {
        guard waitingWatchNote() != nil else { return }
        let request = BGProcessingTaskRequest(identifier: Self.transcriptionTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        // Refused when the system has had enough of us; the next foreground pass
        // simply asks again.
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor private func runScheduledTranscription(_ task: BGTask) async {
        // Chained first: expiry can cut this short at any point, and the next slot
        // has to be asked for while we still can.
        scheduleTranscriptionTask()
        task.expirationHandler = {
            Task { @MainActor [weak self] in self?.audioImports.pause(userInitiated: false) }
        }
        var transcribed = false
        while let job = waitingWatchNote() {
            guard audioImports.activeID == nil, !audioImports.receiving, !keyboard.isActive, canReleaseMemory else { break }
            await releaseModels()
            audioImports.start(job.id, allowBackground: true)
            guard audioImports.activeID == job.id else { break }
            await audioImports.waitForCompletion()
            transcribed = true
        }
        task.setTaskCompleted(success: transcribed)
    }

    /// The oldest watch recording that could run if something were willing to run it.
    private func waitingWatchNote() -> AudioImportJob? {
        audioImports.jobs
            .filter { $0.origin == .watch && ($0.autoStart ?? true)
                      && ($0.status == .pending || $0.status == .paused)
                      && languageLibrary.isPrepared("speech:" + $0.language) }
            .min { $0.createdAt < $1.createdAt }
    }

    /// What this phone has measured about its own speed. Persisted because the
    /// decision below happens seconds after a cold launch, with nothing else to
    /// go on.
    private var speechTimings: SpeechTimings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "speechTimings"),
                  let value = try? JSONDecoder().decode(SpeechTimings.self, from: data) else { return SpeechTimings() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "speechTimings") }
        }
    }

    private func learnSpeechTimings(_ audioSeconds: Double, _ decodeSeconds: Double, _ loadSeconds: Double) {
        var timings = speechTimings
        timings.record(audioSeconds: audioSeconds, decodeSeconds: decodeSeconds, loadSeconds: loadSeconds)
        speechTimings = timings
    }

    /// A recording that arrived while the phone slept is transcribed there and
    /// then when the estimate says it will finish inside the grace period. Being
    /// cut off is survivable but wastes a model load, so anything longer waits and
    /// the arrival banner says so.
    private func startWatchImportInBackground() -> Bool {
        guard audioImports.activeID == nil, !audioImports.receiving, !keyboard.isActive, canReleaseMemory else { return false }
        let waiting = audioImports.jobs.filter {
            $0.origin == .watch && ($0.autoStart ?? true) && ($0.status == .pending || $0.status == .paused)
                && languageLibrary.isPrepared("speech:" + $0.language)
        }
        guard let job = waiting.min(by: { $0.createdAt < $1.createdAt }) else { return false }
        let budget = audioImports.claimBackgroundBudget()
        let timings = speechTimings
        let estimate = BackgroundTranscriptionPolicy.Estimate(
            audioSeconds: Self.audioSeconds(of: job),
            realTimeFactor: timings.realTimeFactor,
            modelLoadSeconds: timings.modelLoadSeconds)
        guard BackgroundTranscriptionPolicy.fitsInBackground(estimate, budgetSeconds: budget) else {
            audioImports.releaseUnusedBudget()
            return false
        }
        audioImports.start(job.id, allowBackground: true)
        return audioImports.activeID == job.id
    }

    /// Read from the file's header rather than decoded: the job only learns its
    /// own length once transcription runs, which is the decision being made here.
    private static func audioSeconds(of job: AudioImportJob) -> Double {
        if job.duration > 0 { return job.duration }
        guard let file = try? AVAudioFile(forReading: job.audioURL) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Asked outside the drain guard on purpose. A cold launch drains twice, once
    /// from the notes screen appearing and once from the scene becoming active,
    /// and the first runs before the app counts as in front. Inside the guard the
    /// second call returned early, so the question was never put and a watch could
    /// deliver for days in silence.
    private func requestWatchNotifications() async {
        // A recording already in hand justifies the offer even when the watch app
        // does not report itself as installed.
        let hasRecordings = !WatchSessionBridge.stagedRecordings().isEmpty
            || audioImports.jobs.contains { $0.origin == .watch }
        await watch.requestNotificationAuthorizationIfNeeded(hasRecordings: hasRecordings)
    }

    /// Chains the recordings: the first one starts, the rest join its queue.
    private func startWatchImport() async {
        var attempted: Set<UUID> = []
        while let id = watchImportCandidate(excluding: attempted) {
            attempted.insert(id)
            await startAudioImport(id)
        }
    }
    private func watchImportCandidate(excluding attempted: Set<UUID>) -> UUID? {
        let candidates = audioImports.jobs
            .filter { $0.origin == .watch && !attempted.contains($0.id) && ($0.status == .pending || $0.status == .queued || $0.status == .paused) }
            .map { WatchImportPolicy.Candidate(id: $0.id, createdAt: $0.createdAt, queued: $0.status == .queued,
                                               autoStart: $0.autoStart ?? true,
                                               prepared: languageLibrary.isPrepared("speech:" + $0.language)) }
        return WatchImportPolicy.next(activeID: audioImports.activeID, receiving: audioImports.receiving,
                                      foreground: UIApplication.shared.applicationState == .active,
                                      keyboardActive: keyboard.isActive, memoryReleasable: canReleaseMemory,
                                      candidates: candidates)
    }
    func importMayUpdate(_ note: VoiceNote) -> Bool { note.transcriptionComplete == false && audioImports.jobs.contains { $0.id == note.id && $0.status != .completed } }
    var showStorage = false
    var storageInventory = ModelStorageInventory()
    var storageLoading = false
    var storageReadFailed = false
    var managingStorage = false
    var storageError: String?
    var storageMessage: String?
    private var preparationBatchCancelled = false
    private var modelWorkCount = 0
    private var preparationResume = PreparationResumePolicy(savedRequest: UserDefaults.standard.string(forKey: "pendingLanguagePreparation"))
    private var resumingPreparation = false
    var preparationPaused: Bool { preparationResume.isPaused }
    var preparationStepIndex = 0
    var preparationStepCount = 1
    var preparationBatchIndex = 0
    var preparationBatchCount = 1
    var preparationFraction: Double? {
        guard !warmingModels else { return nil }
        let current = translationFraction ?? (progress.flatMap { $0.totalUnitCount > 0 ? $0.fractionCompleted : nil }) ?? 0
        return PreparationProgress.fraction(step: preparationStepIndex, steps: preparationStepCount, current: current, batch: preparationBatchIndex, batches: preparationBatchCount)
    }
    var preparationStageLabel: String {
        let batch = preparationBatchCount > 1 ? L10n.format("Language %d of %d", preparationBatchIndex + 1, preparationBatchCount) + " · " : ""
        return batch + L10n.format("Step %d of %d", preparationStepIndex + 1, preparationStepCount) + " · " + preparationModel
    }
    private func persistPreparationRequest() {
        if let request = preparationResume.request { UserDefaults.standard.set(request, forKey: "pendingLanguagePreparation") }
        else { UserDefaults.standard.removeObject(forKey: "pendingLanguagePreparation") }
    }
    private func trackPreparation(_ request: String) -> UUID? {
        if preparingAll && request != "all" { return nil }
        let token = preparationResume.begin(request); persistPreparationRequest(); return token
    }
    private func finishPreparation(_ token: UUID?) {
        if let token { preparationResume.complete(token); persistPreparationRequest() }
    }
    func pauseLanguagePreparation() async {
        guard phase == .preparing || preparingAll, preparationResume.pause() else { return }
        persistPreparationRequest(); error = nil
        await cancel(keepDraft: true, preservingPreparation: true)
        if UIApplication.shared.applicationState == .active { await resumeLanguagePreparation() }
    }
    func resumeLanguagePreparation() async {
        guard !resumingPreparation, preparationResume.isPaused, let pending = preparationResume.request else { return }
        resumingPreparation = true
        var scheduling = true
        defer { if scheduling { resumingPreparation = false } }
        while modelWorkCount > 0 || activePreparationID != nil || preparingAll {
            guard UIApplication.shared.applicationState == .active, preparationResume.request == pending else { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard let request = preparationResume.resumableRequest(isActive: UIApplication.shared.applicationState == .active, isBusy: busy) else { return }
        scheduling = false; resumingPreparation = false
        if request.hasPrefix("preload:") { await preloadLanguages(Set(request.dropFirst(8).split(separator: ",").map(String.init))) }
        else if request == "all" { await prepareAllLanguages() }
        else if request.hasPrefix("speech:") { await prepareSpeechLanguage(String(request.dropFirst(7))) }
        else if request.hasPrefix("translation:") {
            let codes = request.dropFirst(12).split(separator: "-").map(String.init)
            if codes.count == 2 { await prepareTranslationLanguage(.init(source: codes[0], target: codes[1])) }
        }
    }
    @ObservationIgnored private var preparationTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private let modelStorage = ModelStorage(modelsRoot: StoragePaths.models, speech: SpeechAssets.storageLocations(), translationRoot: StoragePaths.translation)
    var canManageStorage: Bool { !busy && !preparingAll && modelWorkCount == 0 && !keyboard.hasPendingPreparation }
    func refreshStorage() async {
        guard !storageLoading else { return }
        storageLoading = true; defer { storageLoading = false }
        do { storageInventory = try await modelStorage.inventory(); storageError = nil; storageReadFailed = false }
        catch { storageReadFailed = true; storageError = error.localizedDescription }
    }
    func deleteStoredModel(_ item: ModelStorageItem) async {
        guard canManageStorage else { return }
        managingStorage = true; storageError = nil; storageMessage = nil
        defer { managingStorage = false; publishWidgetState() }
        await unloadModelOwners()
        invalidatePreparation(for: item)
        do {
            try await modelStorage.remove(id: item.id)
            storageInventory = try await modelStorage.inventory()
            storageMessage = L10n.text(item.downloadable ? "Download removed." : "Download removed.")
        } catch { let message = error.localizedDescription; await refreshStorage(); storageError = message }
    }
    private func invalidatePreparation(for item: ModelStorageItem) {
        guard !item.id.hasPrefix("legacy-") else { return }
        if item.kind == .speech || item.kind == .importedSpeech { languageLibrary.invalidateSpeechPreparation(); return }
        let catalog = TranslationService(modelsRoot: StoragePaths.translation)
        let affected = languageLibrary.translations.filter { pack in
            if item.kind == .incomplete { return true }
            if item.kind == .translationQuality, item.id.hasPrefix("translation/") {
                return catalog.usesQualityDirectoryInAnyScenario(String(item.id.dropFirst("translation/".count)), from: pack.source, to: pack.target)
            }
            let pair = LanguagePair(source: item.source ?? "", target: item.target ?? "")
            return catalog.usesDownloadedModel(pair, from: pack.source, to: pack.target, quality: item.kind == .translationQuality)
        }.map { "translation:" + $0.id }
        languageLibrary.invalidatePrepared(Set(affected))
    }
    func removeSpeechLanguage(_ code: String) async {
        guard canManageStorage else { return }
        managingStorage = true
        defer { managingStorage = false; publishWidgetState() }
        do {
            await unloadModelOwners()
            let inventory = try await modelStorage.inventory()
            let remaining = languageLibrary.speech.filter { $0 != code }
            let unused = LanguageDownloadRemoval.speech(inventory.items, removing: code, remaining: remaining)
            languageLibrary.invalidatePrepared(["speech:" + code])
            for item in unused { try await modelStorage.remove(id: item.id) }
            languageLibrary.removeSpeech(code)
            if source == code, let next = remaining.first {
                source = next; recommendModel()
                UserDefaults.standard.set(source, forKey: "speechLanguage")
                UserDefaults.standard.set(speechModel.rawValue, forKey: "speechModel")
                UserDefaults.standard.set(speechModelSelectionIsExplicit, forKey: "speechModelSelectionIsExplicit")
                UserDefaults.standard.set(mode.rawValue, forKey: "speechMode")
            }
            storageInventory = try await modelStorage.inventory()
        } catch { self.error = error.localizedDescription }
    }
    func removeTranslationLanguage(_ pack: TranslationLanguagePack) async {
        guard canManageStorage else { return }
        managingStorage = true
        defer { managingStorage = false; publishWidgetState() }
        do {
            await unloadModelOwners()
            let inventory = try await modelStorage.inventory()
            let remaining = languageLibrary.translations.filter { $0.id != pack.id }.map { LanguagePair(source: $0.source, target: $0.target) }
            let catalog = TranslationService(modelsRoot: StoragePaths.translation)
            let unused = LanguageDownloadRemoval.translation(inventory.items, removing: .init(source: pack.source, target: pack.target), remaining: remaining) { item, pair in
                if item.kind == .translationQuality, item.id.hasPrefix("translation/") {
                    return catalog.usesQualityDirectoryInAnyScenario(String(item.id.dropFirst("translation/".count)), from: pair.source, to: pair.target)
                }
                return catalog.usesDownloadedModel(.init(source: item.source ?? "", target: item.target ?? ""), from: pair.source, to: pair.target, quality: item.kind == .translationQuality)
            }
            languageLibrary.invalidatePrepared(["translation:" + pack.id])
            for item in unused { try await modelStorage.remove(id: item.id) }
            languageLibrary.removeTranslation(pack)
            storageInventory = try await modelStorage.inventory()
        } catch { self.error = error.localizedDescription }
    }
    var showMemory = false
    var showSettings = false
    var showLanguages = false
    var showTranslation = false
    var translationLoaded = false
    var releasingMemory = false
    var showRecorder = false
    var showKeyboardSetup = false
    var keyboardActivationRequested = false
    let keyboard = KeyboardDictationController()
    private var recordedDuration = 0.0
    var noteList = NoteList(repository: NoteRepository(directory: StoragePaths.notes))
    #if DEBUG
    @ObservationIgnored private var uiTestNote: VoiceNote?
    #endif
    var selectedNote: VoiceNote?
    var transcript = ""
    var captionDisplay = CorrectionDisplay()
    var translation = ""
    var detail = ""
    var error: String?
    var progress: Progress?
    var translationFraction: Double?
    var levels: [CGFloat] = Array(repeating: 0.08, count: 24)
    var startedAt = Date()
    var isTranslation = false
    var preparingLiveTranslation = false
    var conversation = RecordingTranscript()
    var liveTranslationSegments: [UtteranceTranslation] = []
    @ObservationIgnored private var recordingAudio: RecordedAudio?
    private var capturedFrames = 0
    private var sourceFinalized = false
    var modelReady = false
    var warmingModels = false
    var preparationModel = ""
    var importing = false
    var preparingAll = false
    var activePreparationID: String?
    var preparationErrors: [String: String] = [:]
    let languageLibrary = LanguageLibrary()
    var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    var source = UserDefaults.standard.string(forKey: "speechLanguage") ?? "ru"
    var translationQuality = ProcessingQuality(rawValue: UserDefaults.standard.string(forKey: "voiceTranslationQuality") ?? "quality") ?? .quality {
        didSet { UserDefaults.standard.set(translationQuality.rawValue, forKey: "voiceTranslationQuality") }
    }
    var directTranslationEnabled = UserDefaults.standard.bool(forKey: "directSpeechTranslationEnabled") {
        didSet { UserDefaults.standard.set(directTranslationEnabled, forKey: "directSpeechTranslationEnabled") }
    }
    var target = UserDefaults.standard.string(forKey: "targetLanguage") ?? "en"
    var mode = DictationMode(rawValue: UserDefaults.standard.string(forKey: "speechMode") ?? "hybrid") ?? .hybrid
    // Legacy saved recommendations remain automatic; explicit new choices win.
    var speechModelSelectionIsExplicit = SpeechRecognitionProfile.selectionIsExplicit(
        savedFlag: UserDefaults.standard.object(forKey: "speechModelSelectionIsExplicit") as? Bool,
        savedModel: UserDefaults.standard.string(forKey: "speechModel").flatMap(SpeechModelChoice.init(rawValue:)),
        language: UserDefaults.standard.string(forKey: "speechLanguage") ?? "ru")
    var speechModel = SpeechModelChoice(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "gigaam") ?? .gigaam {
        didSet { speechModelSelectionIsExplicit = true }
    }
    @ObservationIgnored var qualifiedSpeechOverrides: [QualifiedSpeechOverride] = []
    @ObservationIgnored var enableQualifiedSpeechProfiles = false
    var speechRecognitionProfile: SpeechRecognitionProfile? {
        try? SpeechRecognitionProfile.resolve(language: source, mode: mode,
            explicitChoice: speechModelSelectionIsExplicit ? speechModel : nil,
            qualifiedOverrides: qualifiedSpeechOverrides,
            enableQualifiedOverrides: enableQualifiedSpeechProfiles)
    }
    private var speechConfigurationKey: String {
        speechRecognitionProfile?.configurationID ?? "unsupported:\(mode.rawValue):\(speechModel.rawValue):\(source)"
    }
    @ObservationIgnored private(set) var speechQualificationTelemetry: SpeechQualificationSnapshot?
    @ObservationIgnored private var speech: RecordingSession?
    @ObservationIgnored private var directSpeech: DirectSpeechSession?
    @ObservationIgnored private var usesDirectTranslation = false
    @ObservationIgnored private var configurationKey = ""
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var noteID = UUID()
    @ObservationIgnored private var lastDraftSave = Date.distantPast
    @ObservationIgnored private var pendingCorrections: Set<UInt64> = []
    @ObservationIgnored private var activity: Activity<RecordingAttributes>?
    @ObservationIgnored private let repository = NoteRepository(directory: StoragePaths.notes)
    var busy: Bool { photoTranslationActive || phase != .idle || importing || keyboard.isActive || releasingMemory || audioImports.busy || textTranslator.isBusy || managingStorage || modelWorkCount > 0 || keyboard.hasPendingPreparation }
    var canReleaseMemory: Bool { !photoTranslationActive && phase == .idle && !importing && !preparingAll && !releasingMemory && !audioImports.busy && !textTranslator.isBusy && !managingStorage && modelWorkCount == 0 && !keyboard.hasPendingPreparation && keyboard.state.phase != .recording && keyboard.state.phase != .finalizing && keyboard.state.phase != .preparing }
    var hasLoadedModels: Bool { textTranslator.modelsLoaded || speech != nil || directSpeech != nil || translationLoaded || keyboard.isActive || audioImports.activeID != nil }
    var directTranslationSelected: Bool {
        DirectSpeechTranslation.shouldUse(enabled: directTranslationEnabled, source: source,
                                          target: target, deviceEligible: Self.directTranslationDeviceEligible)
    }
    var directTranslationUnavailableOnDevice: Bool {
        directTranslationEnabled && DirectSpeechTranslation.supports(source: source, target: target)
            && !Self.directTranslationDeviceEligible
    }

    private var directTranslationAvailable: Bool {
        isTranslation && directTranslationSelected
    }
    private static var directTranslationDeviceEligible: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        ProcessInfo.processInfo.physicalMemory >= 5 * 1_024 * 1_024 * 1_024
        #else
        true
        #endif
    }

    private func recordingSession() -> RecordingSession {
        if let speech { return speech }
        let cap = min(Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.45), 3_500_000_000)
        let session = RecordingSession(modelsRoot: StoragePaths.models,
            translationRoot: StoragePaths.translation, memoryLimit: cap)
        speech = session
        return session
    }
    func refreshMemoryState() async { translationLoaded = (await speech?.residentTranslationModelCount ?? 0) > 0 }
    func translateNote(_ note: VoiceNote, to target: String, onProgress: @escaping @MainActor (Double?) -> Void) async throws {
        guard !busy, !importMayUpdate(note), translationTargets(from: note.sourceLanguage).contains(target) else { throw CancellationError() }
        let session = TextTranslationSession(modelsRoot: StoragePaths.translation)
        do {
            try await performModelWork { [self] in
                await session.setQuality(translationQuality)
                try await session.prepare(from: note.sourceLanguage, to: target) { onProgress($0) }
                onProgress(nil)
                var translatedUtterances = note.utterances
                let result: String
                if var utterances = translatedUtterances, !utterances.isEmpty {
                    for index in utterances.indices {
                        utterances[index].translation = try await session.translate(utterances[index].text, from: note.sourceLanguage, to: target)
                        onProgress(Double(index + 1) / Double(utterances.count))
                    }
                    translatedUtterances = utterances
                    result = utterances.compactMap(\.translation).joined(separator: "\n\n")
                } else { result = try await session.translate(note.text, from: note.sourceLanguage, to: target) }
                try Task.checkCancellation()
                guard var current = try await repository.note(note.id), current.text == note.text else { throw CancellationError() }
                if current.translation != nil { current.transcriptVersions = (current.transcriptVersions ?? []) + [TranscriptVersion(note: current)] }
                current.translation = result; current.targetLanguage = target; current.translationNeedsUpdate = false
                current.translationIncomplete = false
                current.utterances = translatedUtterances
                try await repository.save(current)
                if selectedNote?.id == current.id { selectedNote = current }
                await noteList.reload(preservingCount: true)
            }
        } catch { await session.unload(); throw error }
        await session.unload()
    }
    func enableLiveTranslation(to language: String) async {
        guard phase == .recording, !isTranslation, !preparingLiveTranslation, translationOptions.contains(language) else { return }
        let token = operation
        preparingLiveTranslation = true
        defer { preparingLiveTranslation = false }
        do {
            try await performModelWork { [self] in
                guard let speech else { throw CancellationError() }
                try await speech.setTranslation(target: language, priority: translationQuality)
                try Task.checkCancellation()
                guard operation == token, phase == .recording else { return }
                target = language; isTranslation = true; translationLoaded = true
                UserDefaults.standard.set(language, forKey: "targetLanguage")
            }
        } catch { if operation == token, phase == .recording, !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func releaseModels() async {
        guard canReleaseMemory else { return }
        releasingMemory = true
        await unloadModelOwners()
        releasingMemory = false
        publishWidgetState()
    }
    private func unloadModelOwners() async {
        await keyboard.end()
        if let speech { await speech.unload() }
        if let directSpeech { await directSpeech.close() }
        directSpeech = nil; usesDirectTranslation = false
        speech = nil; configurationKey = ""; modelReady = false
        translationLoaded = false
        await textTranslator.unload()
    }
    func publishWidgetState() {
        let status = phase == .preparing || keyboard.state.phase == .preparing || audioImports.preparing || textTranslator.isBusy ? "Preparing…" : hasLoadedModels ? "Ready" : "Inactive"
        MurMurWidgetState(source: source, target: target, status: status).save()
        // The watch mirrors the same language and readiness this broadcast carries.
        publishWatchContext()
    }
    var duration: Double { phase == .recording ? Double(capturedFrames) / 16_000 : recordedDuration }

    func loadNote(_ id: UUID) async -> VoiceNote? {
        #if DEBUG
        if let uiTestNote, uiTestNote.id == id { return uiTestNote }
        #endif
        do { return try await repository.note(id) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func currentNote(_ fallback: VoiceNote) -> VoiceNote {
        if let selectedNote, selectedNote.id == fallback.id { return selectedNote }
        return fallback
    }
    func importMayUpdate(_ note: NoteSummary) -> Bool {
        note.transcriptionComplete == false && audioImports.jobs.contains { $0.id == note.id && $0.status != .completed }
    }
    func refresh() async {
        do {
            if phase == .idle && !keyboard.isActive && !audioImports.busy {
                for id in try await repository.incompleteRecordingIDs() {
                    guard var note = try await repository.note(id),
                          let audio = note.audio,
                          let url = try? audio.url(in: StoragePaths.recordings),
                          let recoveredDuration = try? PCMRecordingWriter.repair(url), abs(recoveredDuration - note.duration) > 0.05 else { continue }
                    note.duration = recoveredDuration
                    try await repository.save(note)
                }
            }
            if let data = try? Data(contentsOf: StoragePaths.draft), let recovered = try? JSONDecoder().decode(VoiceNote.self, from: data) {
                if try await repository.note(recovered.id) == nil, try await repository.isDeleted(recovered.id) == false {
                    try await repository.save(recovered)
                }
                try? FileManager.default.removeItem(at: StoragePaths.draft)
            }
            await noteList.reload(preservingCount: true)
            if let id = selectedNote?.id { selectedNote = try await repository.note(id) }
        } catch { self.error = error.localizedDescription }
    }

    private func publishLatestNote() async throws {
        guard let latest = StoragePaths.latest else { return }
        let first = try await repository.page(limit: 1).items.first
        let note: VoiceNote?
        if let first { note = try await repository.note(first.id) } else { note = nil }
        try Data((note?.shareText ?? "").utf8).write(to: latest, options: [.atomic, .completeFileProtection])
    }

    func updateSettings() async {
        guard !busy else { return }
        UserDefaults.standard.set(source, forKey: "speechLanguage")
        UserDefaults.standard.set(target, forKey: "targetLanguage")
        UserDefaults.standard.set(mode.rawValue, forKey: "speechMode")
        UserDefaults.standard.set(speechModel.rawValue, forKey: "speechModel")
        UserDefaults.standard.set(speechModelSelectionIsExplicit, forKey: "speechModelSelectionIsExplicit")
        modelReady = false
        publishWidgetState()
    }

    func recommendModel() {
        mode = mode.effective(for: source)
        guard !speechModelSelectionIsExplicit || !speechModel.supports(source) else { return }
        speechModel = SpeechRecognitionProfile.baselineModel(language: source)
        speechModelSelectionIsExplicit = false
    }

    func requestMicrophonePermission() async {
        microphoneAllowed = await withCheckedContinuation { continuation in
            SpeechSession.requestMicrophoneAccess { continuation.resume(returning: $0) }
        }
        if !microphoneAllowed { error = L10n.text("Allow microphone access in Settings to record a note.") }
    }

    func prepareSpeechLanguage(_ code: String) async {
        guard !busy else { return }
        let preparationToken = trackPreparation("speech:" + code)
        defer { finishPreparation(preparationToken) }
        let previous = (source, mode, speechModel, speechModelSelectionIsExplicit)
        let id = "speech:" + code
        activePreparationID = id; preparationErrors[id] = nil
        defer {
            source = previous.0; mode = previous.1; speechModel = previous.2
            speechModelSelectionIsExplicit = previous.3
            modelReady = configurationKey == speechConfigurationKey
            activePreparationID = nil
        }
        languageLibrary.addSpeech(code)
        source = code
        speechModel = SpeechRecognitionProfile.baselineModel(language: code)
        speechModelSelectionIsExplicit = false
        mode = DictationMode.hybrid.effective(for: code)
        await prepareModels()
        if let error { preparationErrors[id] = error; self.error = nil }
    }

    var translationOptions: [String] {
        translationTargets(from: source)
    }
    func translationTargets(from source: String) -> [String] {
        availableTranslationTargets(from: source).filter { ProcessingQuality.translationOptions(from: source, to: $0).contains(translationQuality) }
    }
    func validateTranslationQuality() {
        if !ProcessingQuality.translationOptions(from: source, to: target).contains(translationQuality) { translationQuality = .quality }
    }
    func availableTranslationTargets(from source: String) -> [String] {
        TextTranslationSession.availableTargets(from: source, modelsRoot: StoragePaths.translation)
    }

    func prepareTranslationLanguage(_ pack: TranslationLanguagePack) async {
        guard !busy else { return }
        let preparationToken = trackPreparation("translation:" + pack.id)
        defer { finishPreparation(preparationToken) }
        let id = "translation:" + pack.id
        activePreparationID = id; preparationErrors[id] = nil
        defer { activePreparationID = nil }
        phase = .preparing; error = nil; progress = nil
        preparationStepIndex = 0; preparationStepCount = 2; translationFraction = nil
        operation = UUID(); let token = operation
        preparationModel = "\(AppLanguages.name(pack.source)) → \(AppLanguages.name(pack.target))"
        detail = L10n.text("Preparing translation…")
        do {
            try await performModelWork { [self] in
            try await recordingSession().prepareTranslation(from: pack.source, to: pack.target, priority: .quality) { [weak self] value in
                guard self?.operation == token else { return }
                self?.translationFraction = value.fraction
            }
            translationLoaded = true
            guard operation == token else { return }
            languageLibrary.markPrepared("translation:" + pack.id)
            }
        } catch { if operation == token { preparationErrors[id] = error.localizedDescription } }
        await refreshMemoryState()
        modelReady = speech?.isPrepared == true
        if operation == token { phase = .idle; warmingModels = false; translationFraction = nil }
    }

    func preloadLanguages(_ languages: Set<String>) async {
        guard !busy else { return }
        let plan = OfflinePreloadPlan(languages: languages)
        preparationErrors = [:]
        for code in plan.speech { languageLibrary.addSpeech(code) }
        for pair in plan.translations where availableTranslationTargets(from: pair.source).contains(pair.target) {
            languageLibrary.addTranslation(from: pair.source, to: pair.target)
        }
        // Explicit preload prepares both transcription lanes, regardless of the
        // currently selected processing priority.
        languageLibrary.invalidatePrepared(Set(plan.speech.map { "speech:" + $0 }))
        let pairs = plan.translations.filter { availableTranslationTargets(from: $0.source).contains($0.target) }
            .map { TranslationLanguagePack(source: $0.source, target: $0.target) }
        await prepareLanguageBatch(speechCodes: plan.speech, pairs: pairs, request: "preload:" + plan.speech.joined(separator: ","))
        if canReleaseMemory { await releaseModels() }
    }

    func prepareAllLanguages() async {
        await prepareLanguageBatch(
            speechCodes: languageLibrary.speech.filter { !languageLibrary.isPrepared("speech:" + $0) },
            pairs: languageLibrary.translations.filter { !languageLibrary.isPrepared("translation:" + $0.id) },
            request: "all")
    }
    private func prepareLanguageBatch(speechCodes: [String], pairs: [TranslationLanguagePack], request: String) async {
        guard !busy, !preparingAll else { return }
        let preparationToken = trackPreparation(request)
        preparingAll = true; preparationBatchCancelled = false
        defer {
            preparingAll = false; finishPreparation(preparationToken)
            preparationBatchIndex = 0; preparationBatchCount = 1
        }
        preparationBatchCount = max(1, speechCodes.count + pairs.count)
        for (index, code) in speechCodes.enumerated() {
            guard !preparationBatchCancelled, !Task.isCancelled else { return }
            preparationBatchIndex = index; await prepareSpeechLanguage(code)
        }
        for (index, pair) in pairs.enumerated() {
            guard !preparationBatchCancelled, !Task.isCancelled else { return }
            preparationBatchIndex = speechCodes.count + index; await prepareTranslationLanguage(pair)
        }
    }

    func prepareModels() async {
        guard !busy else { return }
        error = nil
        phase = .preparing; operation = UUID(); let token = operation
        do {
            try await prepare(token: token, translating: false)
            if operation == token { languageLibrary.markPrepared("speech:" + source); publishWatchContext() }
        }
        catch { if operation == token { self.error = L10n.text("Could not prepare this language. Please try again.") } }
        if operation == token { phase = .idle; progress = nil; warmingModels = false }
    }

    private func performModelWork(_ action: @escaping @MainActor () async throws -> Void) async throws {
        let id = UUID()
        modelWorkCount += 1
        let task = Task<Void, Error> { try Task.checkCancellation(); try await action() }
        preparationTasks[id] = task
        defer { preparationTasks[id] = nil; modelWorkCount -= 1 }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func prepare(token: UUID, translating: Bool) async throws {
        try await performModelWork { [self] in try await prepareImpl(token: token, translating: translating) }
    }
    private func prepareImpl(token: UUID, translating: Bool) async throws {
        await textTranslator.unload()
        if usesDirectTranslation && translating {
            if let directSpeech { await directSpeech.close(); self.directSpeech = nil }
            if let speech { await speech.unload() }
            speech = nil; configurationKey = ""; modelReady = false
            translationLoaded = false
            let session = DirectSpeechSession()
            directSpeech = session
            preparationStepCount = 1; preparationStepIndex = 0
            preparationModel = L10n.text("Preparing direct translation…")
            detail = preparationModel; progress = nil
            do {
                try await session.prepare { [weak self] value in
                    guard self?.operation == token else { return }
                    self?.progress = value
                }
                guard operation == token else { await session.close(); throw CancellationError() }
                modelReady = true; progress = nil
                return
            } catch is CancellationError {
                await session.close(); directSpeech = nil
                throw CancellationError()
            } catch {
                await session.close(); directSpeech = nil; usesDirectTranslation = false
                self.error = L10n.text("Direct translation is unavailable. Translation through text will be used.")
                try await prepareImpl(token: token, translating: translating)
                return
            }
        }
        if let directSpeech { await directSpeech.close(); self.directSpeech = nil }
        mode = mode.effective(for: source)
        guard let recognitionProfile = speechRecognitionProfile else {
            throw NSError(domain: "MurMur", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("This language is unavailable in the selected mode.")])
        }
        let key = speechConfigurationKey
        preparationStepCount = translating ? 3 : 2; preparationStepIndex = 0
        let speech = recordingSession()
        wire(speech, token: token)
        modelReady = false
        try await speech.prepare(.init(profile: recognitionProfile,
            target: translating ? target : nil, translationQuality: translationQuality))
        guard operation == token else { await speech.unload(); throw CancellationError() }
        configurationKey = key; modelReady = true
        if translating { translationLoaded = true }
        warmingModels = false; progress = nil; translationFraction = nil
    }

    /// `immediately` skips the "Ready, tap Start" pause after a cold warm-up. The
    /// in-app button keeps it, because a person watching the screen benefits from
    /// knowing when the microphone opened; a shortcut or button press does not.
    func start(translating: Bool = false, immediately: Bool = false) async {
        guard !busy else { return }
        recommendModel()
        operation = UUID(); let token = operation
        let needsConfirmation = !modelReady || configurationKey != speechConfigurationKey || translating
        showRecorder = true; recordedDuration = 0
        error = nil; isTranslation = translating && source != target; phase = .preparing
        usesDirectTranslation = directTranslationAvailable
        detail = L10n.text("Microphone access")
        let allowed = await withCheckedContinuation { continuation in
            SpeechSession.requestMicrophoneAccess { continuation.resume(returning:$0) }
        }
        microphoneAllowed = allowed
        guard allowed else { phase = .idle; showRecorder = false; error = L10n.text("Allow microphone access in Settings to record a note."); return }
        do {
            try await prepare(token: token, translating: isTranslation)
            guard operation == token, UIApplication.shared.applicationState == .active,
                  usesDirectTranslation ? directSpeech != nil : speech != nil else { throw CancellationError() }
            if !usesDirectTranslation { languageLibrary.markPrepared("speech:" + source); publishWatchContext() }
            if isTranslation && !usesDirectTranslation { languageLibrary.markPrepared("translation:" + source + "-" + target) }
            phase = .ready
            detail = L10n.text("Ready. Tap Start recording when you want to speak.")
            if !needsConfirmation || immediately { await confirmRecording() }
        } catch {
            if operation == token { phase = .idle; showRecorder = false; self.error = error is CancellationError ? nil : L10n.text("Could not start dictation. Check microphone access and language downloads.") }
        }
    }

    func confirmRecording() async {
        guard phase == .ready, UIApplication.shared.applicationState == .active else { return }
        guard usesDirectTranslation ? directSpeech != nil : speech != nil else { return }
        let token = operation
        phase = .preparing
        do {
            captionDisplay = CorrectionDisplay(); pendingCorrections = []
            transcript = ""; translation = ""; levels = Array(repeating: 0.08, count: 24)
            conversation = RecordingTranscript(); liveTranslationSegments = []; capturedFrames = 0; sourceFinalized = false
            preparingLiveTranslation = false
            noteID = UUID(); startedAt = Date(); lastDraftSave = .distantPast
            recordingAudio = RecordedAudio(recordingID: noteID)
            try await repository.save(makeNote(duration: 0))
            guard operation == token, phase == .preparing, UIApplication.shared.applicationState == .active else { throw CancellationError() }
            if usesDirectTranslation, let directSpeech {
                directSpeech.onCapture = { [weak self] frames, peak in Task { @MainActor in
                    guard let self, self.operation == token, self.phase == .recording else { return }
                    self.capturedFrames += frames
                    self.levels.append(CGFloat(min(1, max(0.05, peak * 6))))
                    self.levels = Array(self.levels.suffix(24))
                } }
                directSpeech.onError = { [weak self] _ in Task { @MainActor in
                    guard let self, self.operation == token, self.phase == .recording else { return }
                    await self.interrupted()
                } }
                try directSpeech.arm()
                try directSpeech.begin(source: source, target: target,
                    recordingURL: recordingAudio?.url(in: StoragePaths.recordings),
                    onBatch: { [weak self] value in
                        guard let self else { throw CancellationError() }
                        try await self.acceptDirectUtterance(value, token: token)
                    })
            } else if let speech {
                wire(speech, token: token)
                try await speech.start(microphoneUID: "built-in", recordingURL: recordingAudio?.url(in: StoragePaths.recordings))
            } else { throw CancellationError() }
            guard operation == token, phase == .preparing, UIApplication.shared.applicationState == .active else {
                await directSpeech?.close(); if let speech { await speech.unload() }; throw CancellationError()
            }
            phase = .recording
            detail = usesDirectTranslation ? L10n.text("Direct translation") : mode == .hybrid ? L10n.text("Draft first, refined a beat later") : L10n.text("Listening on this iPhone")
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                activity = try? Activity.request(attributes: RecordingAttributes(startedAt: startedAt),
                    content: ActivityContent(state: RecordingAttributes.ContentState(phase: L10n.text("Listening")), staleDate: nil))
            }
        } catch {
            if operation == token {
                if usesDirectTranslation { await directSpeech?.close(); directSpeech = nil; modelReady = false }
                else { modelReady = speech?.isPrepared == true; await refreshMemoryState() }
                phase = .idle; showRecorder = false
                self.error = error is CancellationError ? nil : L10n.text("Could not start dictation. Check microphone access and language downloads.")
            }
        }
    }

    private func acceptDirectUtterance(_ value: RecordedUtterance, token: UUID) async throws {
        guard operation == token, phase == .recording || phase == .refining else { throw CancellationError() }
        conversation.appendSettled(value)
        transcript = conversation.text; translation = conversation.translatedText
        let seconds = Double(value.endSample) / 16_000
        try await repository.save(makeNote(duration: max(duration, seconds)))
        guard operation == token else { throw CancellationError() }
    }

    func enableKeyboard(fromExtension: Bool = false) async {
        guard !photoTranslationActive, phase == .idle, !importing, !preparingAll, !releasingMemory, !audioImports.busy, !textTranslator.isBusy, !managingStorage, modelWorkCount == 0, !keyboard.hasPendingPreparation else { return }
        releasingMemory = true
        defer { releasingMemory = false }
        await textTranslator.unload()
        if let speech { await speech.unload(); self.speech = nil; configurationKey = ""; modelReady = false }
        if let directSpeech { await directSpeech.close(); self.directSpeech = nil; usesDirectTranslation = false; modelReady = false }
        translationLoaded = false
        if fromExtension { await keyboard.activateFromKeyboard() } else { await keyboard.enable() }
    }
    func consumeKeyboardActivation() async {
        guard keyboardActivationRequested, UIApplication.shared.applicationState == .active else { return }
        keyboardActivationRequested = false
        await enableKeyboard(fromExtension: true)
    }

    private func wire(_ speech: RecordingSession, token: UUID) {
        speech.onEvent = { [weak self] event in
            guard let self, self.operation == token else { return }
            switch event {
            case .preparation(let value):
                self.progress = value.fraction.map {
                    let progress = Progress(totalUnitCount: 1_000)
                    progress.completedUnitCount = Int64($0 * 1_000)
                    return progress
                }
                switch value.stage {
                case .unloading:
                    self.preparationModel = L10n.text("Freeing memory…")
                    self.warmingModels = false
                case .speech:
                    self.preparationModel = L10n.text("Preparing dictation…")
                    self.warmingModels = false
                case .translation:
                    self.preparationModel = L10n.text("Preparing translation…")
                    self.translationFraction = value.fraction
                    self.preparationStepIndex = 1
                    self.warmingModels = false
                case .warmup:
                    self.preparationModel = L10n.text("Preparing…")
                    self.warmingModels = true
                    self.preparationStepIndex = self.preparationStepCount - 1
                }
                self.detail = self.preparationModel
            case .telemetry(let snapshot):
                if self.enableQualifiedSpeechProfiles { self.speechQualificationTelemetry = snapshot }
            case .capture(let frames, let peak):
                self.capturedFrames += frames
                self.levels.append(CGFloat(min(1, max(0.05, peak * 6))))
                self.levels = Array(self.levels.suffix(24))
            case .failure(let failure):
                switch failure {
                case .recording(let message), .capture(let message):
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == token else { return }
                        await self.interrupted()
                        self.error = L10n.text("Could not save audio.") + " " + message
                    }
                case .recognition:
                    self.error = L10n.text("Could not refine text. Your draft is still available.")
                case .translation:
                    self.error = L10n.text("Translation could not be completed. Your original text is kept.")
                }
            case .speech(let value):
                guard self.phase == .recording || self.phase == .refining else { return }
                switch value {
                case .correctionStarted(let id, _):
                    self.pendingCorrections.insert(id); self.detail = L10n.text("Refining")
                case .correctionFinished(let id, _, _):
                    self.pendingCorrections.remove(id)
                    self.detail = L10n.text(self.pendingCorrections.isEmpty ? "Text refined" : "Refining")
                case .correctionFailed(let id, _): self.pendingCorrections.remove(id)
                case .draft:
                    if self.pendingCorrections.isEmpty && self.phase == .recording { self.detail = L10n.text("Listening") }
                default: break
                }
            case .snapshot:
                guard self.phase == .recording || self.phase == .refining, let current = self.speech else { return }
                self.conversation = current.transcript
                self.transcript = self.conversation.text
                if self.phase == .recording, Date().timeIntervalSince(self.lastDraftSave) >= 1 {
                    self.lastDraftSave = Date(); self.persistRecoveryDraft()
                }
            case .translation(let text, let segments):
                if self.phase == .recording { self.translation = text }
                self.acceptTranslations(segments, token: token)
            case .state: break
            }
        }
    }

    private func acceptTranslations(_ values: [UtteranceTranslation], token: UUID) {
        guard operation == token, phase == .recording || phase == .refining else { return }
        liveTranslationSegments = values
        if let speech { conversation = speech.transcript }
    }

    func stop() async {
        guard phase == .recording else { return }
        recordedDuration = duration
        phase = .refining; detail = L10n.text("Refining your note…")
        let token = operation
        await activity?.update(ActivityContent(state: RecordingAttributes.ContentState(phase: L10n.text("Refining")), staleDate: nil))
        if usesDirectTranslation, let directSpeech {
            do {
                let result = try await directSpeech.finish()
                guard operation == token else { return }
                directSpeech.disarm()
                recordedDuration = result.duration; capturedFrames = Int(result.duration * 16_000)
                sourceFinalized = true
                transcript = conversation.text; translation = conversation.translatedText
                await saveResult(duration: result.duration)
            } catch {
                guard operation == token else { return }
                directSpeech.disarm()
                self.error = L10n.text("Translation could not be completed. Your original text is kept.")
                sourceFinalized = false
                await saveResult(duration: recordedDuration, complete: false)
            }
            return
        }
        guard let speech else { return }
        do {
            let result = try await speech.stopSource()
            guard operation == token else { return }
            conversation = result.transcript; sourceFinalized = true
            transcript = conversation.text
            // Commit the source before translation can fail, be interrupted, or take time.
            do { try await repository.save(makeNote(duration: result.duration, complete: true)) }
            catch {
                guard operation == token else { return }
                self.error = error.localizedDescription; persistRecoveryDraft()
            }
            guard operation == token else { return }
            do {
                let final = try await speech.finishTranslation()
                guard operation == token else { return }
                conversation = final.transcript
            } catch {
                guard operation == token else { return }
                self.error = L10n.text("Translation could not be completed. Your original text is kept.")
            }
            guard operation == token else { return }
            translation = conversation.translatedText
            await saveResult(duration: result.duration)
        } catch {
            guard operation == token else { return }
            self.error = error.localizedDescription
            await saveResult(duration: recordedDuration, complete: false)
        }
    }

    private func makeNote(duration: Double, complete: Bool = false, captureClosed: Bool = false) -> VoiceNote {
        var note = VoiceNote(id: noteID, createdAt: startedAt, text: conversation.text,
            translation: isTranslation && !conversation.translatedText.isEmpty ? conversation.translatedText : nil,
            sourceLanguage: source, targetLanguage: isTranslation ? target : nil,
            duration: duration, model: usesDirectTranslation ? "direct-speech-translation" : "\(mode.rawValue) · \(speechModel.title)")
        note.audio = recordingAudio; note.utterances = conversation.utterances
        note.captureRevision = conversation.revision; note.transcriptionComplete = complete
        note.captureClosed = captureClosed || complete
        note.translationIncomplete = isTranslation && (!complete || conversation.utterances.contains { $0.translation == nil })
        if note.text.isEmpty { note.sourceFileName = L10n.text("Audio recording") }
        return note
    }
    private func saveResult(duration: Double, complete: Bool = true) async {
        if recordingAudio != nil || !conversation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let note = makeNote(duration: duration, complete: complete, captureClosed: true)
            do {
                try await repository.save(note)
                if let latest = StoragePaths.latest { try? Data(note.shareText.utf8).write(to: latest, options: [.atomic,.completeFileProtection]) }
                try? FileManager.default.removeItem(at: StoragePaths.draft)
                await noteList.reload(preservingCount: true); selectedNote = note
            } catch { self.error = error.localizedDescription; persistRecoveryDraft() }
        }
        await activity?.end(nil, dismissalPolicy: .immediate); activity = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle; showRecorder = false
    }
    private func persistRecoveryDraft() {
        guard recordingAudio != nil || !conversation.text.isEmpty else { return }
        let note = makeNote(duration: duration)
        do {
            try FileManager.default.createDirectory(at: StoragePaths.draft.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(note).write(to: StoragePaths.draft, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Task { do { try await repository.saveProgress(note) } catch { self.error = error.localizedDescription } }
        } catch { self.error = L10n.format("Could not save recovery text: %@", error.localizedDescription) }
    }
    func cancel(keepDraft: Bool = false, preservingPreparation: Bool = false) async {
        let hadRecording = recordingAudio != nil && (phase == .recording || phase == .refining)
        let capturedDuration = duration
        if !preservingPreparation { preparationResume.cancel(); persistPreparationRequest() }
        operation = UUID()
        preparationBatchCancelled = true
        for task in preparationTasks.values { task.cancel() }
        if !keepDraft && !hadRecording { try? FileManager.default.removeItem(at: StoragePaths.draft) }
        if let speech { await speech.unload() }
        if let directSpeech { await directSpeech.close() }
        if hadRecording {
            conversation.finish(fallback: transcript, endSample: Int(capturedDuration * 16_000))
            do { try await repository.save(makeNote(duration: capturedDuration, complete: sourceFinalized, captureClosed: true)); await noteList.reload(preservingCount: true) }
            catch { self.error = error.localizedDescription }
        }
        speech = nil; directSpeech = nil; configurationKey = ""; modelReady = false; usesDirectTranslation = false; translationLoaded = false
        await activity?.end(nil, dismissalPolicy: .immediate); activity = nil
        phase = .idle; showRecorder = false; progress = nil; warmingModels = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func interrupted() async {
        guard phase == .recording else { return }
        persistRecoveryDraft()
        await cancel(keepDraft: true)
        await refresh()
        error = L10n.text("Recording stopped. The captured text was kept.")
    }
    func delete(_ note: VoiceNote) async {
        guard !importMayUpdate(note) else { return }
        do {
            try await repository.delete(note.id); await noteList.reload(preservingCount: true); selectedNote = nil
            if let audio = note.audio, try await repository.hasAudioReference(audio.recordingID) == false,
               !audioImports.jobs.contains(where: { $0.id != note.id && $0.audio?.recordingID == audio.recordingID }) {
                let directory = try audio.url(in: StoragePaths.recordings).deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
            try await publishLatestNote()
        }
        catch { self.error = error.localizedDescription }
    }
    func saveEdit(_ note: VoiceNote) async {
        guard !importMayUpdate(note) else { return }
        do {
            var updated = note
            updated.captureClosed = true
            if let previous = try await repository.note(note.id), previous.text != note.text {
                updated.transcriptVersions = (previous.transcriptVersions ?? []) + [TranscriptVersion(note: previous)]
                updated.utterances = nil
            }
            try await repository.save(updated); await noteList.reload(preservingCount: true); selectedNote = updated
            try await publishLatestNote()
        }
        catch { self.error = error.localizedDescription }
    }
    func audioURL(for note: VoiceNote) -> URL? {
        guard let url = try? note.audio?.url(in: StoragePaths.recordings), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    func retranscribe(_ note: VoiceNote) async {
        guard canReleaseMemory, !busy else { return }
        await releaseModels()
        do {
            let choice = SpeechRecognitionProfile.model(speechModel, for: note.sourceLanguage)
            try audioImports.retranscribe(note, model: choice)
            showAudioImport = true
            await startAudioImport(note.id)
        } catch { self.error = error.localizedDescription }
    }
    func importModels(_ url: URL) async {
        guard !busy else { return }
        importing = true; defer { importing = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let destination = StoragePaths.models
            try await Task.detached { try Self.copyModels(from: url, to: destination) }.value
            if let speech { await speech.unload() }
            speech = nil; configurationKey = ""; translationLoaded = false
            modelReady = false; detail = L10n.text("Languages imported")
        } catch { self.error = error.localizedDescription }
    }

    private nonisolated static func copyModels(from url: URL, to destination: URL) throws {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let allowed = ["CoreMLModels", "ASRModels", "TranslationModels"]
                let entries = allowed.compactMap { name -> URL? in
                    let candidate = url.lastPathComponent == name ? url : url.appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
                }
                guard !entries.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
                for source in entries {
                    let isTranslation = source.lastPathComponent == "TranslationModels"
                    let target = isTranslation ? StoragePaths.translation : destination.appendingPathComponent(source.lastPathComponent)
                    let access = try isTranslation ? ModelFileAccess.acquire(in: target, writing: true) : nil
                    defer { withExtendedLifetime(access) {} }
                    if FileManager.default.fileExists(atPath: target.path) {
                        // Merge exact files; a failed import leaves existing usable files intact.
                        let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey])!
                        for case let file as URL in enumerator {
                            let relative = String(file.path.dropFirst(source.path.count + 1))
                            let output = target.appendingPathComponent(relative)
                            if (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            } else if !FileManager.default.fileExists(atPath: output.path) { try FileManager.default.copyItem(at: file, to: output) }
                        }
                    } else { try FileManager.default.copyItem(at: source, to: target) }
                }
    }

    #if DEBUG
    func seedUITest() {
        let note = VoiceNote(text: "A small idea for tomorrow\nMake room for the things worth saying.", sourceLanguage:"en", duration:18, model:"hybrid")
        uiTestNote = note
        noteList = NoteList(preview: [note])
    }
    #endif
}
