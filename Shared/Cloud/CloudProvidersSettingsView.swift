import Foundation
import SwiftUI
import MurmurCloud
import AIProvidersAuth
import AIProviderViews

// Providers and Models settings, shared by macOS and iOS (design: Claude
// Design «Murmator Mac Settings v1», tabs Providers and Models). Local is the
// absent selection; a connection is one account with its own key.

private func label(_ text: String, _ russian: String) -> String {
    Locale.current.language.languageCode?.identifier == "ru" ? russian : text
}

// MARK: - Logic

/// What each step is called, and what choosing a cloud model for it sends.
extension AIOperation {
    static let settingsOrder: [AIOperation] = [.streamingTranscription, .transcription, .textEditing, .translation]

    var settingsTitle: String {
        switch self {
        case .streamingTranscription: label("Live recognition", "Живое распознавание")
        case .transcription: label("Accurate recognition", "Точное распознавание")
        case .textEditing: label("Corrector", "Корректор")
        case .translation: label("Translation", "Перевод")
        }
    }

    var cloudNote: String {
        switch self {
        case .streamingTranscription: label("Fast and Hybrid. Sends your audio while you speak.", "Fast и Hybrid. Отправляет звук, пока вы говорите.")
        case .transcription: label("Hybrid sends each finished phrase while you speak; Accurate sends the recording after you stop.",
                                   "Hybrid отправляет каждую законченную фразу, пока вы говорите; Accurate — запись после остановки.")
        case .textEditing: label("Sends only the final text.", "Отправляет только итоговый текст.")
        case .translation: label("Sends the text to translate.", "Отправляет текст для перевода.")
        }
    }
}

/// The two-step choice of a step's model: the provider first, then only the
/// models of that provider that can do the step. All reads and writes go
/// through `ProviderPreferences`; nothing here keeps its own copy.
@MainActor
enum ProviderModelChoice {
    /// Connections offered for a step: those that can do it (an empty or reset
    /// model list doesn't mean they can't; searching shows the real answer),
    /// plus the one already chosen.
    static func providers(for operation: AIOperation, in preferences: ProviderPreferences) -> [AIConnection] {
        let chosen = preferences.selection(operation)?.connectionID
        return preferences.connections.filter { $0.id == chosen || preferences.supports(operation, connection: $0) }
    }

    static func models(for operation: AIOperation, of connection: AIConnection, in preferences: ProviderPreferences) -> [AIModel] {
        (preferences.catalogs[connection.id.uuidString] ?? []).filter { $0.operations.contains(operation) }
    }

    static let localTag = "local"
    static let noModelTag = ""

    /// What the two pop-ups show. A provider picked but not yet given a model
    /// (`draft`) is shown with no model, and changes nothing saved: a cloud
    /// model may cost money, so it is never chosen on the user's behalf.
    /// A draft whose connection was deleted, or no longer has a model for the
    /// step, is ignored: the saved choice shows again.
    static func displayed(_ operation: AIOperation, draft: UUID?, in preferences: ProviderPreferences) -> (provider: String, model: String) {
        let selection = preferences.selection(operation)
        if let draft, draft != selection?.connectionID,
           providers(for: operation, in: preferences).contains(where: { $0.id == draft }) {
            return (draft.uuidString, noModelTag)
        }
        guard let selection else { return (localTag, noModelTag) }
        return (selection.connectionID.uuidString, selection.modelID)
    }

    /// Local takes effect at once; a model takes effect with its provider.
    static func chooseLocal(for operation: AIOperation, in preferences: ProviderPreferences) throws {
        try preferences.select(nil, for: operation)
    }

    static func choose(_ modelID: String, of connectionID: UUID, for operation: AIOperation, in preferences: ProviderPreferences) throws {
        let old = preferences.selection(operation)
        let options = old?.connectionID == connectionID && old?.modelID == modelID ? old?.options : nil
        try preferences.select(.init(connectionID: connectionID, modelID: modelID, options: options), for: operation)
    }

    /// The chosen model is kept even when the provider's last list lacks it
    /// (offline, renamed): shown by its saved id, never silently replaced.
    static func savedModelIsMissing(_ operation: AIOperation, in preferences: ProviderPreferences) -> Bool {
        guard let selection = preferences.selection(operation),
              let connection = preferences.connections.first(where: { $0.id == selection.connectionID }) else { return false }
        return !models(for: operation, of: connection, in: preferences).contains { $0.id == selection.modelID }
    }

    /// A model's name from the connection's loaded models, else its saved id.
    static func modelName(_ id: String, of connection: AIConnection, in preferences: ProviderPreferences) -> String {
        preferences.catalogs[connection.id.uuidString]?.first { $0.id == id }?.name ?? id
    }

    /// Steps that fall back to Local when this connection is deleted.
    static func stepsUsing(_ id: UUID, in preferences: ProviderPreferences) -> [AIOperation] {
        AIOperation.settingsOrder.filter { preferences.selection($0)?.connectionID == id }
    }
}

/// The result of checking a connection's model list in this session. Kept
/// app-wide so a check survives switching tabs; nothing is claimed for a
/// connection that was not checked.
@MainActor @Observable
final class ProviderChecks {
    static let shared = ProviderChecks()

    /// `verified` is false when the provider's list is built in, so a check
    /// proves nothing about the key or the endpoint.
    enum State: Equatable { case checking, failed(String), checked(models: Int, verified: Bool) }
    enum Tone { case idle, busy, ok, error }

    private(set) var states: [UUID: State] = [:]
    /// Only the latest check of a connection may write its state: an older one
    /// finishing later (after an edit, or a delete) is dropped.
    private var generations: [UUID: Int] = [:]

    func check(_ connection: AIConnection, in preferences: ProviderPreferences) async {
        await check(connection.id, verifies: preferences.refreshVerifiesConnection(connection.provider)) {
            try await preferences.refresh(connection)
            return preferences.modelCount(connection)
        }
    }

    func check(_ id: UUID, verifies: Bool, refresh: @MainActor () async throws -> Int) async {
        generations[id, default: 0] += 1
        let mine = generations[id]
        states[id] = .checking
        let result: State?
        do {
            result = .checked(models: try await refresh(), verified: verifies)
        } catch is CancellationError {
            result = nil
        } catch {
            result = .failed(error.localizedDescription)
        }
        guard generations[id] == mine else { return }
        states[id] = result
    }

    func forget(_ id: UUID) {
        generations[id, default: 0] += 1
        states[id] = nil
    }

    static func summary(_ state: State?, savedModels: Int?) -> (text: String, tone: Tone) {
        switch state {
        case .checking: (label("Checking…", "Проверяю…"), .busy)
        case .failed(let message): (label("Couldn’t check: ", "Не удалось проверить: ") + message, .error)
        case .checked(let count, true): (label("Checked · \(count) models", "Проверено · моделей: \(count)"), .ok)
        case .checked(let count, false):
            (label("\(count) models listed · connection not verified", "Моделей в списке: \(count) · подключение не проверено"), .idle)
        case nil:
            if let savedModels { (label("\(savedModels) models from an earlier check", "Моделей из прошлой проверки: \(savedModels)"), .idle) }
            else { (label("Not checked yet", "Ещё не проверено"), .idle) }
        }
    }
}

enum ProviderKinds {
    static let all = [("dictator", "Dictator"), ("openai", "OpenAI"), ("openaiCompatible", "OpenAI-compatible"),
                      ("openrouter", "OpenRouter"), ("featherless", "Featherless"), ("anthropic", "Anthropic"), ("deepgram", "Deepgram")]

    static func name(_ provider: String) -> String { all.first { $0.0 == provider }?.1 ?? provider }

    /// The Base URL a new connection starts with; API paths are added to it.
    static func defaultEndpoint(_ provider: String) -> String {
        switch provider {
        case "openai", "openaiCompatible": "https://api.openai.com/v1"
        case "openrouter": "https://openrouter.ai/api/v1"
        case "featherless": "https://api.featherless.ai/v1"
        case "anthropic": "https://api.anthropic.com/v1"
        case "deepgram": "https://api.deepgram.com/v1"
        case "dictator": "https://dictator-gateway-1281256944.europe-west1.run.app/v1"
        default: ""
        }
    }

    static func baseURLHint(_ provider: String) -> String {
        switch provider {
        case "dictator": label("The base URL of your Dictator gateway, with an optional /v1 suffix. Full /v1/audio/transcriptions URLs are also accepted. Use your Dictator API key.",
                               "Базовый URL вашего Dictator gateway, можно с /v1. Полный адрес с /v1/audio/transcriptions тоже поддерживается. Используйте свой API-ключ Dictator.")
        case "openaiCompatible": label("Any server with the OpenAI Chat Completions API. API paths are added to this address.",
                                       "Любой сервер с API OpenAI Chat Completions. Пути API добавляются к этому адресу.")
        default: label("API paths are added to this address, so it usually ends in /v1.",
                       "Пути API добавляются к этому адресу, поэтому обычно он заканчивается на /v1.")
        }
    }

    static func detail(_ connection: AIConnection) -> String {
        connection.auth == .chatGPTPlan ? label("ChatGPT plan", "Тариф ChatGPT")
            : "\(name(connection.provider)) · " + label("API key", "API-ключ")
    }
}

// MARK: - Model picker

/// A step's provider, then its model. With Local chosen, `local` shows the
/// on-device model and its settings, whether or not the step is switched on.
struct ProviderModelPicker<Local: View>: View {
    let operation: AIOperation
    let title: String
    @Bindable var preferences: ProviderPreferences
    var onChange: () -> Void
    @ViewBuilder var local: () -> Local
    /// A provider picked but not yet given a model; nothing saved changes until then.
    @State private var draft: UUID?
    /// The connection whose model list is open.
    @State private var browsing: AIConnection?
    @State private var error: String?

    /// `preferences` nil is the app's shared store (a default argument can't reach the main actor).
    @MainActor
    init(operation: AIOperation, title: String, preferences: ProviderPreferences? = nil,
         onChange: @escaping () -> Void = {}, @ViewBuilder local: @escaping () -> Local) {
        self.operation = operation; self.title = title; self.preferences = preferences ?? .shared
        self.onChange = onChange; self.local = local
    }

    var body: some View {
        let shown = ProviderModelChoice.displayed(operation, draft: draft, in: preferences)
        let connection = preferences.connections.first { $0.id.uuidString == shown.provider }
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(label("Provider", "Провайдер")) {
                Picker(title, selection: Binding(get: { shown.provider }, set: { value in
                    if value == ProviderModelChoice.localTag {
                        draft = nil
                        run { try ProviderModelChoice.chooseLocal(for: operation, in: preferences) }
                    } else {
                        draft = UUID(uuidString: value)
                    }
                })) {
                    Text(label("Local", "Локально")).tag(ProviderModelChoice.localTag)
                    ForEach(ProviderModelChoice.providers(for: operation, in: preferences)) { Text($0.name).tag($0.id.uuidString) }
                }
                .labelsHidden()
                .accessibilityLabel(title)
            }
            if let connection {
                LabeledContent(label("Model", "Модель")) {
                    Button { browsing = connection } label: {
                        HStack(spacing: 6) {
                            Text(shown.model == ProviderModelChoice.noModelTag ? label("Choose a model…", "Выберите модель…")
                                 : ProviderModelChoice.modelName(shown.model, of: connection, in: preferences))
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(label("Model", "Модель"))
                    .accessibilityValue(shown.model == ProviderModelChoice.noModelTag ? label("None chosen", "Не выбрана") : shown.model)
                    .accessibilityHint(label("Opens a searchable list of this provider’s models", "Открывает список моделей провайдера с поиском"))
                }
                if shown.model == ProviderModelChoice.noModelTag {
                    Text(label("Nothing changes until you choose a model.", "Ничего не изменится, пока вы не выберете модель."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if ProviderModelChoice.savedModelIsMissing(operation, in: preferences) {
                    Text(label("Saved as \(shown.model); not among the models loaded so far. It stays chosen.",
                               "Сохранено как \(shown.model); среди загруженных пока моделей её нет. Выбор сохранён."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if [.textEditing, .translation].contains(operation),
                   ["openai", "openaiCompatible", "featherless", "openrouter"].contains(connection.provider),
                   let saved = preferences.selection(operation), saved.connectionID == connection.id, saved.modelID == shown.model {
                    ProviderTextOptions(operation: operation, connection: connection, preferences: preferences, onChange: onChange)
                        .id("\(connection.id)-\(saved.modelID)")
                }
                Text(operation.cloudNote).font(.caption).foregroundStyle(.secondary)
            } else {
                local()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(item: $browsing) { connection in browser(connection) }
    }

    /// The provider's models for this step only; picking one is the only change.
    private func browser(_ connection: AIConnection) -> some View {
        let saved = preferences.selection(operation).flatMap { $0.connectionID == connection.id ? $0.modelID : nil }
        return AIModelBrowser(
            title: label("\(operation.settingsTitle) model · \(connection.name)", "\(operation.settingsTitle): модель · \(connection.name)"),
            message: label("Only models that can do this step are listed. Nothing changes until you pick one.",
                           "Показаны только модели, подходящие для этого шага. Ничего не изменится, пока вы не выберете модель."),
            selectedModelID: saved,
            selectedModelName: saved.map { ProviderModelChoice.modelName($0, of: connection, in: preferences) },
            search: { query, cursor in
                try await preferences.searchModels(connection, operation: operation, query: query, cursor: cursor)
            },
            onSelect: { picked in
                run { try ProviderModelChoice.choose(picked.id, of: connection.id, for: operation, in: preferences) }
                if error == nil { draft = nil }
                browsing = nil
            },
            onCancel: { browsing = nil })
    }

    private func run(_ change: () throws -> Void) {
        do { try change(); error = nil; onChange() } catch { self.error = error.localizedDescription }
    }
}

extension ProviderModelPicker where Local == EmptyView {
    @MainActor init(operation: AIOperation, title: String, preferences: ProviderPreferences? = nil, onChange: @escaping () -> Void = {}) {
        self.init(operation: operation, title: title, preferences: preferences, onChange: onChange) { EmptyView() }
    }
}

/// Per-step settings travel with the chosen model. Recording sessions capture
/// them before starting, just like the endpoint and its credential.
struct ProviderTextOptions: View {
    let operation: AIOperation
    let connection: AIConnection
    @Bindable var preferences: ProviderPreferences
    var onChange: () -> Void
    @State private var serverNames = ""
    @State private var error: String?
    @State private var expanded = false

    init(operation: AIOperation, connection: AIConnection, preferences: ProviderPreferences,
         onChange: @escaping () -> Void, initiallyExpanded: Bool = false) {
        self.operation = operation; self.connection = connection; self.preferences = preferences; self.onChange = onChange
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var selected: AISelection? { preferences.selection(operation) }
    private var options: AITextOptions { selected?.options ?? .init() }
    private var routing: AIProviderRouting { options.routing ?? .init() }
    private var capabilities: AIReasoningCapabilities? {
        preferences.catalogs[connection.id.uuidString]?.first { $0.id == selected?.modelID }?.reasoning
    }
    private var efforts: [AIReasoningEffort] {
        if let capabilities { return capabilities.availableEfforts }
        return AIReasoningEffort.allCases.filter { $0 != .instant || connection.provider == "openaiCompatible" }
    }

    var body: some View {
        DisclosureGroup(label("Reasoning and routing", "Рассуждения и маршрутизация"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if capabilities == nil || !efforts.isEmpty || options.reasoningEffort != nil {
                    Picker(label("Reasoning", "Уровень рассуждений"), selection: Binding<AIReasoningEffort?>(
                        get: { options.reasoningEffort }, set: { value in
                            var updated = options; updated.reasoningEffort = value; save(updated)
                        })) {
                        Text(label("Automatic", "Автоматически")).tag(nil as AIReasoningEffort?)
                        ForEach(efforts, id: \.self) { effort in
                            Text(effort.rawValue).tag(Optional(effort))
                        }
                        if let saved = options.reasoningEffort, !efforts.contains(saved) {
                            Text(label("Saved: \(saved.rawValue)", "Сохранено: \(saved.rawValue)")).tag(Optional(saved))
                        }
                    }
                    if let saved = options.reasoningEffort, !efforts.contains(saved) {
                        Text(label("This level is no longer listed for this model. Choose Automatic or a supported level.",
                                   "Этот уровень больше не указан для модели. Выберите «Автоматически» или поддерживаемый уровень."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let fastest = capabilities?.fastestEffort {
                        Button(label("Use fastest supported", "Выбрать самый быстрый поддерживаемый")) {
                            var updated = options; updated.reasoningEffort = fastest; save(updated)
                        }
                    } else if capabilities == nil {
                        Text(label("This catalog does not list reasoning levels. Choose a level only if your model supports it.",
                                   "В каталоге нет уровней рассуждений. Выбирайте уровень, только если ваша модель его поддерживает."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if connection.provider == "openrouter" {
                    Picker(label("Server routing", "Выбор сервера"), selection: Binding<AIRoutingSort?>(
                        get: { routing.sort }, set: { value in
                            var route = routing; route.sort = value; saveRoute(route)
                        })) {
                        Text(label("Automatic", "Автоматически")).tag(nil as AIRoutingSort?)
                        Text(label("Lowest latency", "Минимальная задержка")).tag(Optional(AIRoutingSort.latency))
                        Text(label("Highest throughput", "Максимальная скорость генерации")).tag(Optional(AIRoutingSort.throughput))
                        Text(label("Lowest price", "Минимальная цена")).tag(Optional(AIRoutingSort.price))
                    }
                    Toggle(label("Allow fallback servers", "Разрешить резервные серверы"), isOn: Binding(
                        get: { routing.allowFallbacks }, set: { value in
                            var route = routing; route.allowFallbacks = value; saveRoute(route)
                        }))
                    LabeledContent(label("Only servers", "Только серверы")) {
                        TextField(label("Any server", "Любой сервер"), text: $serverNames)
                            .onSubmit(applyServers)
                            .accessibilityLabel(label("Only servers", "Только серверы"))
                            .accessibilityHint(label("Comma-separated server IDs, for example groq, cerebras", "Идентификаторы серверов через запятую, например groq, cerebras"))
                    }
                    Button(label("Apply servers", "Применить серверы"), action: applyServers)
                    Text(label("For example: groq, cerebras. Leave blank to allow any server. Your API key stays with OpenRouter.",
                               "Например: groq, cerebras. Пустое поле разрешает любой сервер. Ваш API-ключ остаётся у OpenRouter."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(label("Changes apply to the next recording or translation.", "Изменения применятся к следующей записи или переводу."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if !options.isDefault {
                    Button(label("Reset model settings", "Сбросить настройки модели")) { save(.init()) }
                }
            }
            .padding(.top, 8)
        }
        .onAppear { serverNames = routing.only.joined(separator: ", ") }
        .onChange(of: routing.only) { _, value in serverNames = value.joined(separator: ", ") }
    }

    private func applyServers() {
        let text = serverNames.trimmingCharacters(in: .whitespacesAndNewlines)
        var route = routing
        route.only = text.isEmpty ? [] : text.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        saveRoute(route)
    }
    private func saveRoute(_ route: AIProviderRouting) {
        var updated = options; updated.routing = route.isDefault ? nil : route; save(updated)
    }
    private func save(_ updated: AITextOptions) {
        do { try preferences.setTextOptions(updated, for: operation); error = nil; onChange() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - Models

/// Every step's provider and model, for embedding (iOS). `local` is the
/// app's own editor for a step run on the device (its real settings and keys);
/// the default only says the step runs here. macOS lays the pickers out in its
/// own cards instead.
struct ProviderModelsSettingsView<Local: View>: View {
    var preferences: ProviderPreferences
    var onChange: () -> Void
    @ViewBuilder var local: (AIOperation) -> Local

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(AIOperation.settingsOrder, id: \.self) { operation in
                VStack(alignment: .leading, spacing: 8) {
                    Text(operation.settingsTitle).font(.headline)
                    ProviderModelPicker(operation: operation, title: operation.settingsTitle,
                                        preferences: preferences, onChange: onChange) { local(operation) }
                }
            }
        }
    }
}

extension ProviderModelsSettingsView {
    @MainActor init(preferences: ProviderPreferences? = nil, onChange: @escaping () -> Void = {},
                    @ViewBuilder local: @escaping (AIOperation) -> Local) {
        self.preferences = preferences ?? .shared; self.onChange = onChange; self.local = local
    }
}

extension ProviderModelsSettingsView where Local == Text {
    @MainActor init(preferences: ProviderPreferences? = nil, onChange: @escaping () -> Void = {}) {
        self.init(preferences: preferences, onChange: onChange) { _ in
            Text(label("On this device", "На этом устройстве")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Connections

/// The built-in Local provider and every cloud connection: add, edit, check, delete.
struct ProviderConnectionsSettingsView: View {
    @Bindable var preferences: ProviderPreferences = .shared
    var checks: ProviderChecks = .shared
    var onChange: () -> Void = {}
    @State private var editing: ConnectionDraft?
    @State private var deleting: AIConnection?
    @State private var error: String?
    #if os(macOS)
    @State private var signIn: ChatGPTLoopbackSignIn?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            localRow
            ForEach(preferences.connections) { connectionRow($0) }
            HStack {
                Button(label("Add API key…", "Добавить API-ключ…")) { editing = .add() }
                #if os(macOS)
                Button(signIn == nil ? label("Continue with ChatGPT", "Войти через ChatGPT") : label("Signing in…", "Вход…")) { connectChatGPT() }
                    .disabled(signIn != nil)
                if signIn != nil { Button(label("Cancel", "Отмена")) { signIn?.cancel() } }
                #endif
            }
            Text(label("Keys stay in this app’s Keychain and are never shown again. Two accounts of one provider are two connections.",
                       "Ключи хранятся в Keychain этого приложения и больше не показываются. Два аккаунта одного провайдера — два подключения."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        }
        .accessibilityIdentifier("cloud-provider-settings")
        .sheet(item: $editing) { draft in
            ConnectionEditor(draft: draft, preferences: preferences) { saved, recheck in
                editing = nil
                onChange()
                if recheck { Task { await checks.check(saved, in: preferences); onChange() } }
            } cancel: { editing = nil }
        }
        .confirmationDialog(deleting.map { label("Delete “\($0.name)”?", "Удалить «\($0.name)»?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { connection in
            Button(label("Delete", "Удалить"), role: .destructive) { delete(connection) }
            Button(label("Cancel", "Отмена"), role: .cancel) {}
        } message: { connection in
            Text(deleteMessage(connection))
        }
    }

    private var localRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(label("On this device", "На этом устройстве")).fontWeight(.semibold)
                Text(label("Built in · always available", "Встроенный · всегда доступен")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func connectionRow(_ connection: AIConnection) -> some View {
        let state = checks.states[connection.id]
        // The server's total (Featherless lists tens of thousands), not the page kept on this device.
        let saved = preferences.catalogs[connection.id.uuidString] == nil ? nil : preferences.modelCount(connection)
        let summary = ProviderChecks.summary(state, savedModels: saved)
        return HStack(alignment: .top, spacing: 12) {
            Text(verbatim: String(ProviderKinds.name(connection.provider).prefix(1)))
                .fontWeight(.bold).frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).fontWeight(.semibold)
                Text(ProviderKinds.detail(connection)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if state == .checking { ProgressView().controlSize(.mini) }
                    else { Circle().fill(color(summary.tone)).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(summary.text).font(.caption)
                        .foregroundStyle(summary.tone == .error ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button(label("Check", "Проверить")) { Task { await checks.check(connection, in: preferences); onChange() } }
                .disabled(state == .checking)
            Button(label("Edit…", "Изменить…")) { editing = .edit(connection) }
            Button(label("Delete…", "Удалить…"), role: .destructive) { deleting = connection }
                .accessibilityLabel(label("Delete \(connection.name)", "Удалить \(connection.name)"))
        }
        .accessibilityIdentifier("provider-connection-\(connection.id.uuidString)")
    }

    private func color(_ tone: ProviderChecks.Tone) -> Color {
        switch tone { case .idle: .secondary; case .busy: .orange; case .ok: .green; case .error: .red }
    }

    private func deleteMessage(_ connection: AIConnection) -> String {
        let steps = ProviderModelChoice.stepsUsing(connection.id, in: preferences).map(\.settingsTitle)
        let uses = steps.isEmpty ? label("No step uses it.", "Ни один шаг его не использует.")
            : label("\(steps.joined(separator: ", ")) use it and switch back to Local.",
                    "\(steps.joined(separator: ", ")) используют его и вернутся к локальным моделям.")
        return uses + " " + label("Its key is removed from this device. This can’t be undone.",
                                  "Ключ будет удалён с этого устройства. Это нельзя отменить.")
    }

    private func delete(_ connection: AIConnection) {
        do {
            try preferences.remove(connection.id)
            checks.forget(connection.id)
            error = nil
            onChange()
        } catch { self.error = error.localizedDescription }
        deleting = nil
    }

    #if os(macOS)
    private func connectChatGPT() {
        let flow = ChatGPTLoopbackSignIn(); signIn = flow
        var host = UserDefaults.standard.string(forKey: "ai.chatgpt.hostID")
        if host == nil { host = "urn:uuid:\(UUID())"; UserDefaults.standard.set(host, forKey: "ai.chatgpt.hostID") }
        let hostID = host!
        Task { @MainActor in
            defer { signIn = nil }
            do {
                let session = try await flow.authorize(hostID: hostID, appName: "Murmator")
                let connection = AIConnection(provider: "openai", name: session.email ?? "ChatGPT", endpoint: URL(string: "https://api.openai.com/v1")!, auth: .chatGPTPlan)
                try preferences.addChatGPT(connection, session: session)
                error = nil
                onChange()
                await checks.check(connection, in: preferences)
                onChange()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
    #endif
}

/// What the editor works on: a new API-key connection, or an existing one.
struct ConnectionDraft: Identifiable {
    let id: UUID
    let existing: AIConnection?

    static func add() -> Self { .init(id: UUID(), existing: nil) }
    static func edit(_ connection: AIConnection) -> Self { .init(id: connection.id, existing: connection) }
}

/// Add or edit. The saved key is never read back: an empty key field keeps it.
/// A ChatGPT-plan connection only changes its name.
struct ConnectionEditor: View {
    let draft: ConnectionDraft
    let preferences: ProviderPreferences
    let saved: (AIConnection, _ recheck: Bool) -> Void
    let cancel: () -> Void
    @State private var provider = "dictator"
    @State private var name = ""
    @State private var endpoint = ""
    @State private var key = ""
    @State private var error: String?

    private var isPlan: Bool { draft.existing?.auth == .chatGPTPlan }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existing == nil ? label("Add your API key", "Добавить свой API-ключ") : label("Edit connection", "Изменить подключение"))
                .font(.title2)
            if draft.existing == nil {
                Picker(label("Provider", "Провайдер"), selection: $provider) {
                    ForEach(ProviderKinds.all, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: provider) { _, new in
                    endpoint = ProviderKinds.defaultEndpoint(new); name = ProviderKinds.name(new)
                }
            } else {
                LabeledContent(label("Provider", "Провайдер"), value: ProviderKinds.detail(draft.existing!))
            }
            TextField(label("Connection name", "Название подключения"), text: $name)
            if isPlan {
                LabeledContent(label("Base URL", "Базовый URL"), value: draft.existing!.endpoint.absoluteString)
            } else {
                TextField(label("Base URL", "Базовый URL"), text: $endpoint)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                SecureField(draft.existing == nil ? label("Your API key", "Ваш API-ключ")
                                                  : label("New API key — leave empty to keep the current one", "Новый API-ключ — пусто, чтобы оставить текущий"),
                            text: $key)
                Text(ProviderKinds.baseURLHint(provider)).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button(label("Cancel", "Отмена")) { key = ""; cancel() }
                Spacer()
                Button(draft.existing == nil ? label("Save and check", "Сохранить и проверить") : label("Save", "Сохранить")) { save() }
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(minWidth: 380)
        .onAppear {
            if let existing = draft.existing {
                provider = existing.provider; name = existing.name; endpoint = existing.endpoint.absoluteString
            } else {
                name = ProviderKinds.name(provider); endpoint = ProviderKinds.defaultEndpoint(provider)
            }
        }
        .onDisappear { key = "" }
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if isPlan { return !trimmedName.isEmpty }
        return !trimmedName.isEmpty && !endpoint.isEmpty && (draft.existing != nil || !key.isEmpty)
    }

    private func save() {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            if let existing = draft.existing {
                var updated = existing
                updated.name = trimmedName
                if !isPlan {
                    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        error = label("Enter an HTTPS Base URL, like https://api.example.com/v1", "Укажите HTTPS базовый URL, например https://api.example.com/v1"); return
                    }
                    updated.endpoint = url
                }
                try preferences.update(updated, key: trimmedKey.isEmpty ? nil : trimmedKey)
                key = ""
                saved(updated, updated.endpoint != existing.endpoint || !trimmedKey.isEmpty)
            } else {
                guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    error = label("Enter an HTTPS Base URL, like https://api.example.com/v1", "Укажите HTTPS базовый URL, например https://api.example.com/v1"); return
                }
                let connection = AIConnection(provider: provider, name: trimmedName, endpoint: url)
                try preferences.add(connection, key: trimmedKey)
                key = ""
                saved(connection, true)
            }
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Container

/// Providers then Models in one view, for embedding where there are no tabs (iOS).
struct CloudProvidersSettingsView: View {
    var preferences: ProviderPreferences = .shared
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label("Connections", "Подключения")).font(.headline)
            ProviderConnectionsSettingsView(preferences: preferences, onChange: onChange)
            Divider()
            Text(label("Models by step", "Модели по шагам")).font(.headline)
            ProviderModelsSettingsView(preferences: preferences, onChange: onChange)
        }
    }
}
