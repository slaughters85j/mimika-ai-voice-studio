//
//  AppSettingsView.swift
//  mimika-ai-voice-studio
//
//  App-wide settings reachable from any tab via the gear icon in the
//  global header (next to the Voice Manager) or via Cmd+,. Contains
//  configuration that applies across tabs:
//
//    * Local LLM endpoint base URL + model. Drives the AI Writer in Single Voice
//      and Multi-Talk *and* the Chat tab — was previously locked inside
//      the Chat settings sheet, which made no sense as those features
//      moved out of Chat-only territory.
//    * Pocket-TTS chunk-budget slider. Affects every synthesize call in
//      Single Voice, Multi-Talk, and Chat.
//
//  Chat-scoped fields (voice for chat replies, chat system prompt) live
//  in ChatSettingsView, reachable only from the Chat tab's own gear icon.

import SwiftData
import SwiftUI

struct AppSettingsView: View {
    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    /// Two-way binding to AppState's `pocketTTSChunkBudget`. Edited live
    /// from the slider in this view; persistence is handled by
    /// `AppState.didSet` so no save button is needed for this field.
    @Binding var chunkBudget: Int
    /// The SwiftData endpoint row holding `baseURL`. We don't `@Bindable`
    /// it directly — the view keeps a snapshot in `workingBaseURL` so
    /// Cancel can discard edits, matching the rest of the Done/Cancel
    /// UX. Done writes back to `endpoint.baseURL`.
    let endpoint: LocalLLMEndpoint
    let onSave: (ChatSettings) -> Void

    @State private var workingCopy: ChatSettings
    @State private var workingBaseURL: String
    @State private var availableModels: [String] = []
    @State private var modelLoadError: String? = nil
    @State private var probeState: ProbeState = .idle
    @State private var personaConfig = PersonaProviderStore.load()
    @State private var anthropicKey = PersonaProviderStore.anthropicAPIKey()
    @State private var anthropicProbe: ProbeState = .idle

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        chunkBudget: Binding<Int>,
        endpoint: LocalLLMEndpoint,
        onSave: @escaping (ChatSettings) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self._chunkBudget = chunkBudget
        self.endpoint = endpoint
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
        self._workingBaseURL = State(initialValue: endpoint.baseURL)
    }

    enum ProbeState: Equatable {
        case idle
        case probing
        case ok(String)
        case fail(String)
    }

    var body: some View {
        ModalContainer(title: "App Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                lmStudioSection
                Divider().background(Theme.borderColor)
                personaWriterSection
                Divider().background(Theme.borderColor)
                pocketTTSTuningSection
                Divider().background(Theme.borderColor)
                readAloudSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .task { await loadModels() }
    }

    // MARK: - Sections

    private var lmStudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Local LLM Endpoint").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
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
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("appSettings.modelPicker")
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { Task { await loadModels() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Refresh model list")
                .accessibilityIdentifier("appSettings.refreshModels")
            }

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

    private var personaWriterSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Ensemble Persona Writer").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
            Text("Who writes the cast when you create an Ensemble. Local uses the endpoint above; Claude uses the Anthropic API with structured outputs for more reliable, on-spec casts. Synthesis always stays on-device.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Provider").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                Picker("", selection: $personaConfig.kind) {
                    ForEach(PersonaProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("appSettings.personaProvider")
            }

            if personaConfig.kind == .anthropic {
                HStack {
                    Text("API Key").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                    SecureField("sk-ant-…", text: $anthropicKey)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                        .themeInputField()
                        .accessibilityIdentifier("appSettings.anthropicKey")
                    anthropicProbeDot
                }
                .task(id: anthropicKey + "|" + personaConfig.anthropicModel) {
                    await probeAnthropicKey()
                }
                HStack {
                    Text("Model").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                    Picker("", selection: $personaConfig.anthropicModel) {
                        ForEach(PersonaProviderStore.anthropicModels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("appSettings.anthropicModel")
                }
                Text("Stored in your Keychain — get a key at console.anthropic.com. Haiku is fastest/cheapest; Opus is most capable.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var anthropicProbeDot: some View {
        switch anthropicProbe {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().controlSize(.mini)
        case .ok:
            HStack(spacing: Theme.space1) {
                Circle().fill(Theme.successFG).frame(width: 8, height: 8)
                Text("valid").font(Theme.fontXS).foregroundStyle(Theme.successFG)
            }
            .help("API key valid")
            .accessibilityIdentifier("appSettings.anthropicKeyOK")
        case let .fail(reason):
            HStack(spacing: Theme.space1) {
                Circle().fill(Theme.errorFG).frame(width: 8, height: 8)
                Text(reason).font(Theme.fontXS).foregroundStyle(Theme.errorFG)
            }
        }
    }

    /// Validate the entered Anthropic key against /v1/models (debounced). The
    /// key isn't saved until Done — this probes the in-field value live.
    private func probeAnthropicKey() async {
        guard personaConfig.kind == .anthropic else { anthropicProbe = .idle; return }
        let key = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { anthropicProbe = .idle; return }
        anthropicProbe = .probing
        try? await Task.sleep(for: .milliseconds(600))   // debounce typing
        if Task.isCancelled { return }
        do {
            let models = try await AnthropicMessagesClient(apiKey: key).listModels()
            if !models.isEmpty, !models.contains(personaConfig.anthropicModel) {
                anthropicProbe = .fail("model unavailable")
            } else {
                anthropicProbe = .ok("valid")
            }
        } catch {
            anthropicProbe = .fail("invalid key")
        }
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
                        get: { Double(chunkBudget) },
                        set: { chunkBudget = Int($0.rounded()) }
                    ),
                    in: 15...50,
                    step: 1
                )
                .accessibilityIdentifier("appSettings.chunkBudgetSlider")

                Text("\(chunkBudget) tok")
                    .font(Theme.fontXS.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 56, alignment: .trailing)
                    .monospacedDigit()

                Button(action: { chunkBudget = 50 }) {
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

    /// Stock + imported Pocket-TTS voices for the read-aloud picker (mirrors the
    /// menu-bar list).
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

    private func saveAndClose() {
        // baseURL lives in SwiftData now — write the working snapshot
        // back to the endpoint row. SwiftData's autosave persists.
        if endpoint.baseURL != workingBaseURL {
            endpoint.baseURL = workingBaseURL
            endpoint.updatedAt = .now
        }
        // Remaining fields (model, etc.) still live in ChatSettings.
        settings = workingCopy
        onSave(workingCopy)
        // Persona-writer provider config (UserDefaults) + API key (Keychain).
        PersonaProviderStore.save(personaConfig)
        PersonaProviderStore.setAnthropicAPIKey(anthropicKey)
        isPresented = false
    }

    private func loadModels() async {
        modelLoadError = nil
        guard let url = URL(string: workingBaseURL) else {
            modelLoadError = "Invalid URL"
            return
        }
        let client = LocalLLMClient(baseURL: url)
        do {
            let list = try await client.listModels()
            availableModels = list
            // Re-select the loaded model when the saved one isn't served (e.g. the
            // user swapped the loaded model in LM Studio) — keeps this picker, the
            // Connected pill, and the live requests all in agreement.
            if (workingCopy.model.isEmpty || !list.contains(workingCopy.model)), let first = list.first {
                workingCopy.model = first
            }
        } catch {
            modelLoadError = "Couldn't reach \(workingBaseURL)"
        }
    }

    private func testConnection() async {
        probeState = .probing
        guard let url = URL(string: workingBaseURL) else {
            probeState = .fail("invalid URL")
            return
        }
        let client = LocalLLMClient(baseURL: url)
        do {
            let list = try await client.listModels()
            if let first = list.first {
                probeState = .ok(first)
            } else {
                probeState = .fail("no models")
            }
        } catch {
            probeState = .fail("unreachable")
        }
    }
}
