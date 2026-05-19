//
//  AppSettingsView.swift
//  pocket-tts-macos
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
                pocketTTSTuningSection
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

    private var pocketTTSTuningSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Pocket-TTS Tuning")
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
            if workingCopy.model.isEmpty, let first = list.first {
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
