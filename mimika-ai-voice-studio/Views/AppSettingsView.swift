//
//  AppSettingsView.swift
//  mimika-ai-voice-studio
//
//  App-wide settings reachable from any tab via the gear icon in the global header (next to the Voice Manager) or via Cmd+,. Contains configuration that applies across tabs:
//
//    * Local LLM endpoint base URL + model. Drives the AI Writer in Single Voice and Multi-Talk *and* the Chat tab — was previously locked inside the Chat settings sheet, which made no sense as those features moved out of Chat-only territory.
//    * Pocket-TTS chunk-budget slider. Affects every synthesize call in Single Voice, Multi-Talk, and Chat.
//
//  Chat-scoped fields (voice for chat replies, chat system prompt) live in ChatSettingsView, reachable only from the Chat tab's own gear icon.

import AppKit
import SwiftData
import SwiftUI

struct AppSettingsView: View {
    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    /// Two-way binding to AppState's `pocketTTSChunkBudget`, written only by Done. The slider edits `workingChunkBudget` instead, because writing straight through made this the one control in the sheet that Cancel could not undo.
    @Binding var chunkBudget: Int
    /// The SwiftData endpoint row holding `baseURL`. We don't `@Bindable` it directly — the view keeps a snapshot in `workingBaseURL` so Cancel can discard edits, matching the rest of the Done/Cancel UX. Done writes back to `endpoint.baseURL`.
    let endpoint: LocalLLMEndpoint
    let onSave: (ChatSettings, String) -> Void

    @State private var workingCopy: ChatSettings
    @State private var workingBaseURL: String
    /// Slider-side snapshot of `chunkBudget`, committed by Done and dropped by Cancel.
    @State private var workingChunkBudget: Int
    /// Downloaded / catalog models for the picker (may include unloaded).
    @State private var availableModels: [String] = []
    /// Currently loaded/serving ids (for ✓ markers + connection truth).
    @State private var loadedModels: [String] = []
    @State private var modelLoadError: String? = nil
    @State private var modelLoadStatus: ModelLoadStatus = .idle
    /// Bumps when the user picks a new model so a slower prior load is abandoned.
    @State private var modelLoadGeneration: Int = 0
    /// When true, programmatic model assignment (refresh) must not trigger load.
    @State private var suppressModelAutoLoad = false
    @State private var probeState: ProbeState = .idle
    @State private var personaConfig = PersonaProviderStore.load()
    /// Claude key edits staged for Done (MAVS-52). The saved key itself is never loaded into the UI — only its hint.
    @State private var newAnthropicKey = ""
    @State private var newAnthropicKeyVerified = false
    @State private var removeSavedAnthropicKey = false
    private let savedAnthropicKeyHint = PersonaProviderStore.keyHint(PersonaProviderStore.anthropicAPIKey())

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        chunkBudget: Binding<Int>,
        endpoint: LocalLLMEndpoint,
        onSave: @escaping (ChatSettings, String) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self._chunkBudget = chunkBudget
        self.endpoint = endpoint
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
        self._workingBaseURL = State(initialValue: endpoint.baseURL)
        self._workingChunkBudget = State(initialValue: chunkBudget.wrappedValue)
    }

    enum ProbeState: Equatable {
        case idle
        case probing
        case ok(String)
        case fail(String)
    }

    /// In-flight / result of loading a picker selection into LM Studio.
    enum ModelLoadStatus: Equatable {
        case idle
        case loading(String)
        case verifying(String)
        case loaded(String)
        case failed(String, reason: String)

        var isBusy: Bool {
            switch self {
            case .loading, .verifying: return true
            default: return false
            }
        }
    }

    var body: some View {
        ModalContainer(title: "App Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        lmStudioSection
                        CapabilityOverrideSettingsSection(
                            settings: $workingCopy,
                            endpoint: workingBaseURL
                        )
                        Divider().background(Theme.borderColor)
                        ClaudeSettingsSection(
                            config: $personaConfig,
                            newKey: $newAnthropicKey,
                            removeSavedKey: $removeSavedAnthropicKey,
                            newKeyVerified: $newAnthropicKeyVerified,
                            savedKeyHint: savedAnthropicKeyHint
                        )
                        Divider().background(Theme.borderColor)
                        pocketTTSTuningSection
                        Divider().background(Theme.borderColor)
                        readAloudSection
                        Divider().background(Theme.borderColor)
                        AppInformationSection()
                    }
                }
                .frame(maxHeight: maxBodyHeight)
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .task { await loadModels() }
        .onChange(of: workingCopy.model) { _, newModel in
            guard !suppressModelAutoLoad else { return }
            let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Already live — don't re-hit the load API.
            if loadedModels.contains(where: { idsRoughlyMatch($0, trimmed) }) {
                modelLoadStatus = .loaded(trimmed)
                modelLoadError = nil
                return
            }
            Task { await loadSelectedModel(userPicked: trimmed) }
        }
    }

    /// Cap the scrolling body so the whole sheet fits the screen it opens on. A macOS sheet sizes itself to its content, and this settings stack is taller than a MacBook Air's usable height, so with no cap the sheet grew past the top and bottom of the screen and Cancel/Done became unreachable. The reserve covers the pinned header, the pinned action row, and a margin off the screen edges. Below the cap the sheet still sizes to its content, so a large display is unaffected.
    private var maxBodyHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return max(320, visibleHeight - 200)
    }

    // MARK: - Sections

    private var lmStudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.space2) {
                Text("Local LLM Endpoint").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                lmStudioDownloadBadge
            }
            Text("OpenAI-compatible HTTP API — works with LM Studio, Ollama, llama.cpp server, vLLM, LocalAI, etc. Used by the AI Writer in Single Voice and Multi-Talk, and by Chat for streaming replies.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Base URL").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                TextField("http://localhost:1234", text: $workingBaseURL)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space2)
                    .themeInputField()
                    .accessibilityIdentifier("appSettings.baseURL")
            }

            HStack {
                Text("Model").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                Picker("", selection: $workingCopy.model) {
                    Text("(none yet)").tag("")
                    ForEach(availableModels, id: \.self) { id in
                        Text(modelPickerLabel(for: id)).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(modelLoadStatus.isBusy)
                .accessibilityIdentifier("appSettings.modelPicker")
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { Task { await loadModels() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .disabled(modelLoadStatus.isBusy)
                .help("Refresh downloaded catalog + loaded status")
                .accessibilityIdentifier("appSettings.refreshModels")
            }

            modelLoadStatusRow

            Toggle("Load this model automatically at launch", isOn: $workingCopy.autoLoadModelAtLaunch)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("appSettings.autoLoadModel")

            Text(catalogStatusCaption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            if let modelLoadError {
                Text(modelLoadError)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack(spacing: Theme.space2) {
                Button(action: { Task { await testConnection() } }) {
                    Text("Test Connection")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(probeState == .probing)

                switch probeState {
                case .idle: EmptyView()
                case .probing:
                    ProgressView().controlSize(.mini)
                case let .ok(model):
                    Text("✓ \(model)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.successFG)
                case let .fail(reason):
                    Text("✗ \(reason)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.errorFG)
                }
            }
        }
    }

    private var isSelectedModelLoaded: Bool {
        guard !workingCopy.model.isEmpty else { return false }
        return loadedModels.contains { idsRoughlyMatch($0, workingCopy.model) }
    }

    private var catalogStatusCaption: String {
        let catalog = availableModels.count
        let loaded = loadedModels.count
        if catalog == 0 && loaded == 0 { return "" }
        return "\(catalog) downloaded · \(loaded) loaded"
    }

    /// Live load progress under the picker — only shows success after re-query.
    @ViewBuilder
    private var modelLoadStatusRow: some View {
        switch modelLoadStatus {
        case .idle:
            // The picker auto-loads on a change, so a pick that is already correct but not running has no way to be started — this is that control. Idle with nothing picked stays silent.
            if !workingCopy.model.isEmpty, !isSelectedModelLoaded {
                HStack(spacing: Theme.space2) {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(Theme.textSecondary)
                        .font(.system(size: 12))
                    Text("Not loaded — \(shortModelName(workingCopy.model))")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Load") {
                        Task { await loadSelectedModel(userPicked: workingCopy.model) }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
                }
                .accessibilityIdentifier("appSettings.modelNotLoaded")
            } else {
                EmptyView()
            }
        case let .loading(id):
            HStack(spacing: Theme.space2) {
                ProgressView().controlSize(.mini)
                Text("Loading \(shortModelName(id))…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.warningFG)
                Text("This can take a minute for large models.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("appSettings.modelLoading")
        case let .verifying(id):
            HStack(spacing: Theme.space2) {
                ProgressView().controlSize(.mini)
                Text("Verifying \(shortModelName(id)) is ready…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.warningFG)
            }
            .accessibilityIdentifier("appSettings.modelVerifying")
        case let .loaded(id):
            HStack(spacing: Theme.space2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.successFG)
                    .font(.system(size: 12))
                Text("Loaded — \(shortModelName(id))")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.successFG)
                Button("Eject") {
                    Task { await ejectSelectedModel() }
                }
                .buttonStyle(.plain)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.accent)
                .help("Unload this model and free its memory on the server")
            }
            .accessibilityIdentifier("appSettings.modelLoaded")
        case let .failed(id, reason):
            HStack(spacing: Theme.space2) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.errorFG)
                    .font(.system(size: 12))
                Text("Failed to load \(shortModelName(id)) — \(reason)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
                    .lineLimit(2)
                Button("Retry") {
                    Task { await loadSelectedModel(userPicked: id) }
                }
                .buttonStyle(.plain)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.accent)
                .disabled(modelLoadStatus.isBusy)
            }
            .accessibilityIdentifier("appSettings.modelLoadFailed")
        }
    }

    private func modelPickerLabel(for id: String) -> String {
        loadedModels.contains(where: { idsRoughlyMatch($0, id) }) ? "● \(id)" : id
    }

    private func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    private func idsRoughlyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.hasSuffix(b) || b.hasSuffix(a) { return true }
        let ta = a.split(separator: "/").last.map(String.init) ?? a
        let tb = b.split(separator: "/").last.map(String.init) ?? b
        return ta == tb
    }

    /// Badge that deep-links to LM Studio’s macOS arm64 download when the app isn’t installed; grayed out when `LM Studio.app` is already on disk.
    private var lmStudioDownloadBadge: some View {
        let installed = LMStudioInstall.isInstalled
        return Button {
            guard !installed else { return }
            NSWorkspace.shared.open(LMStudioInstall.downloadURL)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(installed ? "LM Studio installed" : "Get LM Studio")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(installed ? Theme.textSecondary : Theme.badgeSingleFG)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(installed ? Theme.bgTertiary.opacity(0.6) : Theme.badgeSingleBG)
            )
        }
        .buttonStyle(.plain)
        .disabled(installed)
        .opacity(installed ? 0.7 : 1)
        .help(installed
              ? "LM Studio is installed on this Mac"
              : "Download LM Studio — free local LLM app (macOS Apple Silicon)")
        .accessibilityIdentifier("appSettings.lmStudioDownload")
    }

    private var pocketTTSTuningSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Synthesis Tuning")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Lower the chunk budget if you hear distortion on long sentences or packed multi-sentence chunks. Smaller chunks reduce AR-error accumulation per chunk at the cost of more chunk-boundary resets. 50 matches the Python reference (fp32); 30 is a safer starting point for our fp16 model.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.space3) {
                Text("Chunk budget")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 110, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(workingChunkBudget) },
                        set: { workingChunkBudget = Int($0.rounded()) }
                    ),
                    in: 15...50,
                    step: 1
                )
                .accessibilityIdentifier("appSettings.chunkBudgetSlider")

                Text("\(workingChunkBudget) tok")
                    .font(Theme.fontXS.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56, alignment: .trailing)
                    .monospacedDigit()

                Button(action: { workingChunkBudget = 50 }) {
                    Text("Reset")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reset chunk budget to Python reference default (50)")
            }
        }
    }

    private var readAloudSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Read Aloud & Menu Bar")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Adds a menu-bar voice picker and a system “Read Selection Aloud” service. Select text in any app, then right-click → Services — or assign a shortcut in System Settings → Keyboard Shortcuts → Services. Reads aloud with mimika’s on-device engine.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable Read Aloud + menu bar", isOn: $workingCopy.readAloudEnabled)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("appSettings.readAloudEnabled")

            if workingCopy.readAloudEnabled {
                HStack {
                    Text("Voice").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $workingCopy.readAloudVoiceID) {
                        VoicePickerFallback.unavailableTag(
                            selection: workingCopy.readAloudVoiceID,
                            isKnown: readAloudVoiceOptions.contains { $0.id == workingCopy.readAloudVoiceID }
                        )
                        ForEach(readAloudVoiceOptions, id: \.id) { opt in
                            Text(opt.name).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("appSettings.readAloudVoice")
                }
                Toggle("Keep mimika in the menu bar at login", isOn: $workingCopy.launchAtLogin)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    /// Stock + imported Pocket-TTS voices for the read-aloud picker (mirrors the menu-bar list).
    private var readAloudVoiceOptions: [(id: String, name: String)] {
        let stock = BundledVoice.stockIDs.sorted().map {
            (id: $0, name: BundledVoice(predefined: $0).name)
        }
        let imported = VoiceManager.shared.voices
            .filter { $0.pocketTTSKVPath != nil }
            .map { (id: "imported:\($0.id)", name: $0.isEnhanced ? "✨ \($0.name)" : $0.name) }
        return stock + imported
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: cancel) {
                Text("Cancel")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
            }
            .buttonStyle(.plain)

            Button(action: saveAndClose) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appSettings.doneButton")
        }
    }

    // MARK: - Actions

    private func cancel() {
        isPresented = false
    }

    /// Save and close, with no side effect beyond that. Done used to start a model load and block dismissal on it for up to two minutes, which is the wrong job for a button the user reaches for after changing an unrelated setting. Loading a model is now only ever something the user asks for: the picker loads on a change, and the status row's Load button covers a pick that is already correct but not running. Nothing is stranded by this, because a completion request against an unloaded model makes LM Studio load it anyway — `LocalLLMClient` gives those requests a 600 s timeout for exactly that reason.
    private func saveAndClose() {
        onSave(workingCopy, workingBaseURL)
        chunkBudget = workingChunkBudget
        PersonaProviderStore.save(personaConfig)
        // A pasted key is stored only once it has passed the check against the chosen model; an unverified one is dropped, never saved.
        if newAnthropicKeyVerified {
            PersonaProviderStore.setAnthropicAPIKey(newAnthropicKey)
        } else if removeSavedAnthropicKey {
            PersonaProviderStore.removeAnthropicAPIKey()
        }
        isPresented = false
    }

    /// Unload the selected model and free its memory on the server, leaving the pick in place so the status row falls back to "Not loaded — X" with its Load button. The generation bump matters: a `loadSelectedModel` verify poll may still be running, and without it that poll would re-publish `.loaded` seconds after the eject and the row would lie.
    private func ejectSelectedModel() async {
        let model = workingCopy.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, let url = URL(string: workingBaseURL) else { return }

        modelLoadGeneration += 1
        let client = LocalLLMClient(baseURL: url)
        do {
            try await client.unloadModel(named: model)
            loadedModels = (try? await client.listServingModels()) ?? []
            modelLoadStatus = .idle
            modelLoadError = nil
            probeState = .idle
        } catch {
            modelLoadStatus = .failed(model, reason: "could not unload")
        }
    }

    private func loadModels() async {
        modelLoadError = nil
        guard let url = URL(string: workingBaseURL) else {
            modelLoadError = "Invalid URL"
            return
        }
        let client = LocalLLMClient(baseURL: url)
        do {
            // Picker = full downloaded catalog; loaded list is separate (truth).
            async let catalogTask = client.listCatalogModels()
            async let servingTask = client.listServingModels()
            let catalog = try await catalogTask
            let serving = try await servingTask
            availableModels = Self.preferChatModelsFirst(catalog)
            loadedModels = serving

            if catalog.isEmpty {
                modelLoadError = "Server reachable — no models in catalog"
                return
            }
            if serving.isEmpty {
                modelLoadError = "Server reachable — no model loaded (pick one from the list)"
            } else {
                modelLoadError = nil
            }
            // Prefer keeping the saved pick if it's still in the catalog. Only auto-jump when empty/missing — never jump to an embedding model when a chat LLM is available. Suppress auto-load for programmatic sets.
            suppressModelAutoLoad = true
            defer { suppressModelAutoLoad = false }
            if workingCopy.model.isEmpty
                || !catalog.contains(where: { idsRoughlyMatch($0, workingCopy.model) }) {
                if let firstLoaded = serving.first(where: { !LocalLLMClient.isLikelyEmbeddingModel($0) })
                    ?? serving.first {
                    workingCopy.model = firstLoaded
                    modelLoadStatus = .loaded(firstLoaded)
                } else if let firstChat = catalog.first(where: { !LocalLLMClient.isLikelyEmbeddingModel($0) })
                    ?? catalog.first {
                    workingCopy.model = firstChat
                    // Not loaded — user can pick another; don't auto-load on refresh.
                    modelLoadStatus = .idle
                }
            } else if isSelectedModelLoaded {
                modelLoadStatus = .loaded(workingCopy.model)
            }
        } catch {
            modelLoadError = LocalLLMClient.friendlyConnectionError(error)
        }
    }

    /// Unload others + load `model` in LM Studio, then **poll** until the serving list confirms it (or we time out). Status UI stays honest the whole way.
    private func loadSelectedModel(userPicked model: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: workingBaseURL) else {
            modelLoadError = "Invalid URL"
            modelLoadStatus = .failed(trimmed, reason: "invalid URL")
            return
        }

        modelLoadGeneration += 1
        let generation = modelLoadGeneration
        modelLoadError = nil
        modelLoadStatus = .loading(trimmed)
        probeState = .probing

        let client = LocalLLMClient(baseURL: url)

        // Already live — verify once and finish.
        if let serving = try? await client.listServingModels(),
           serving.contains(where: { idsRoughlyMatch($0, trimmed) }) {
            guard generation == modelLoadGeneration else { return }
            loadedModels = serving
            modelLoadStatus = .loaded(trimmed)
            probeState = .ok(trimmed)
            return
        }

        do {
            _ = try await client.switchToModel(trimmed)
            guard generation == modelLoadGeneration else { return }
            modelLoadStatus = .verifying(trimmed)

            // Poll load state — load API can return before the instance is listed.
            let deadline = Date().addingTimeInterval(120)
            var lastServing: [String] = []
            while Date() < deadline {
                guard generation == modelLoadGeneration else { return }
                let serving = try await client.listServingModels()
                lastServing = serving
                loadedModels = serving
                if serving.contains(where: { idsRoughlyMatch($0, trimmed) }) {
                    modelLoadStatus = .loaded(trimmed)
                    probeState = .ok(trimmed)
                    modelLoadError = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }

            guard generation == modelLoadGeneration else { return }
            let reason = lastServing.isEmpty
                ? "timed out waiting for load"
                : "load finished but model not listed as loaded"
            modelLoadStatus = .failed(trimmed, reason: reason)
            probeState = .fail(reason)
            modelLoadError = reason
        } catch {
            guard generation == modelLoadGeneration else { return }
            let reason = LocalLLMClient.friendlyConnectionError(error)
            modelLoadStatus = .failed(trimmed, reason: reason)
            modelLoadError = "Couldn't load model — \(reason)"
            probeState = .fail(reason)
        }
    }

    /// Prove the server is reachable **and** has a model loaded for chat. Does not treat the downloaded catalog as “connected.”
    private func testConnection() async {
        probeState = .probing
        guard let url = URL(string: workingBaseURL) else {
            probeState = .fail("invalid URL")
            return
        }
        let client = LocalLLMClient(baseURL: url)
        do {
            async let catalogTask = client.listCatalogModels()
            async let servingTask = client.listServingModels()
            let catalog = try await catalogTask
            let serving = try await servingTask
            availableModels = Self.preferChatModelsFirst(catalog)
            loadedModels = serving

            let chatLoaded = serving.filter { !LocalLLMClient.isLikelyEmbeddingModel($0) }
            let selected = workingCopy.model.trimmingCharacters(in: .whitespacesAndNewlines)

            // Selected model must be loaded — not “some other model is loadable.”
            if !selected.isEmpty {
                if serving.contains(where: { idsRoughlyMatch($0, selected) }) {
                    if LocalLLMClient.isLikelyEmbeddingModel(selected) {
                        probeState = .fail("embedding model loaded — pick a chat LLM")
                        modelLoadError = "Selected model is for embeddings, not chat"
                    } else {
                        probeState = .ok(selected)
                        modelLoadError = nil
                    }
                    return
                }
                if serving.isEmpty {
                    probeState = .fail("no model loaded")
                    modelLoadError = "Server reachable — no model loaded (pick one from the list)"
                } else {
                    let live = chatLoaded.first ?? serving.first ?? "?"
                    probeState = .fail("selected model not loaded")
                    modelLoadError = "Loaded: \(live) — pick that model, or wait for your selection to finish loading"
                }
                return
            }

            if let live = chatLoaded.first {
                suppressModelAutoLoad = true
                workingCopy.model = live
                suppressModelAutoLoad = false
                modelLoadStatus = .loaded(live)
                probeState = .ok(live)
                modelLoadError = nil
            } else if !serving.isEmpty {
                probeState = .fail("no chat model loaded")
                modelLoadError = "Only embedding model(s) loaded — pick a chat LLM"
            } else if catalog.isEmpty {
                probeState = .fail("no models")
            } else {
                probeState = .fail("no model loaded")
                modelLoadError = "Server reachable — no model loaded (pick one from the list)"
            }
        } catch {
            probeState = .fail(LocalLLMClient.friendlyConnectionError(error))
        }
    }

    /// Chat LLMs first in the picker; embeddings last.
    private static func preferChatModelsFirst(_ ids: [String]) -> [String] {
        let chat = ids.filter { !LocalLLMClient.isLikelyEmbeddingModel($0) }
        let embed = ids.filter { LocalLLMClient.isLikelyEmbeddingModel($0) }
        return chat + embed
    }
}

// MARK: - LM Studio install detection

/// Detects a local LM Studio.app and provides the official macOS arm64 download.
enum LMStudioInstall {
    /// Official latest macOS Apple Silicon build (redirects to current version).
    static let downloadURL = URL(string: "https://lmstudio.ai/download/latest/darwin/arm64")!

    /// True when LM Studio.app is present in common install locations.
    static var isInstalled: Bool {
        let candidates = [
            "/Applications/LM Studio.app",
            "/Applications/AI/LM Studio.app",
            NSHomeDirectory() + "/Applications/LM Studio.app",
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
