//
//  ScriptGeneratorModal.swift
//  pocket-tts-macos
//
//  Overlay for AI-powered script generation. The user types a natural
//  language description, the connected LLM streams a formatted script,
//  and "Use Script" commits it to the text editor.
//
//  Each mode (Single Voice / Multi-Talk) has its own system prompt,
//  editable inline via a disclosure toggle. Changes persist through the
//  ChatSettings binding back to AppState → UserDefaults.

import SwiftData
import SwiftUI

struct ScriptGeneratorModal: View {
    @Binding var isPresented: Bool
    let mode: ScriptGeneratorMode
    @Binding var chatSettings: ChatSettings
    let onAccept: (_ script: String, _ speakerNames: [String]) -> Void

    /// SwiftData context — used to resolve the active LLM endpoint URL
    /// without needing AppState injected through every parent view.
    @Environment(\.modelContext) private var modelContext

    @State private var generator = ScriptGenerator()
    @State private var prompt: String = ""
    @State private var speakerCount: Int = 2
    @State private var showsPromptManager = false

    var body: some View {
        ModalContainer(title: modalTitle, onClose: dismiss) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                connectionRow
                promptField
                if mode == .multiTalk { speakerCountPicker }
                systemPromptSection
                generateButton
                if !generator.preview.isEmpty { previewArea }
                if case .error(let msg) = generator.status { errorLabel(msg) }
                if generator.status == .done { acceptRow }
            }
            .frame(maxWidth: 560)
        }
        .task { await generator.checkConnection(settings: chatSettings, baseURL: currentEndpointBaseURL()) }
        .sheet(isPresented: $showsPromptManager) {
            PromptManagerSheet(isPresented: $showsPromptManager, scope: promptScope)
        }
    }

    /// Map the generator's mode onto the SwiftData `PromptScope`.
    private var promptScope: PromptScope {
        mode == .singleVoice ? .singleVoice : .multiTalk
    }

    /// Pull the user-configured LLM endpoint URL from SwiftData. Reads
    /// fresh on every modal presentation so changes made in App
    /// Settings between sessions take effect without restart.
    private func currentEndpointBaseURL() -> String {
        AppDataStore
            .loadOrSeedEndpoint(modelContext, fallbackBaseURL: chatSettings.baseURL)
            .baseURL
    }

    /// Fetch the active SystemPrompt's content for this modal's scope.
    /// Falls back to the hardcoded default if none is marked active
    /// (shouldn't happen after first-launch migration but keeps the
    /// generator from sending an empty system prompt).
    private func activePromptContent() -> String {
        if let active = AppDataStore.activePrompt(modelContext, scope: promptScope) {
            return active.content
        }
        return PromptManagerSheet.hardcodedDefault(for: promptScope)
    }

    // MARK: - Title

    private var modalTitle: String {
        mode == .singleVoice ? "AI Script Writer" : "AI Script Writer — Multi-Talk"
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack {
            ConnectionStatusPill(state: generator.connectionState)
            Spacer()
        }
    }

    // MARK: - Prompt

    private var promptField: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Describe what you'd like")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            // Swapped from SwiftUI's TextField(axis: .vertical) to the
            // NSTextView-backed MacTextEditor for two reasons:
            //   * Enter / Shift+Enter / Cmd+Enter behave properly in
            //     NSTextView (TextField on macOS consumes Enter as a
            //     submit signal and doesn't reliably insert a newline
            //     even with axis: .vertical).
            //   * Fixed-height container with the editor's built-in
            //     NSScrollView lets long instructions scroll instead
            //     of pushing the rest of the modal off-screen.
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("e.g. A woman talking about planting flowers…")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4 + 4)
                        .padding(.vertical, Theme.space3 + 4)
                        .allowsHitTesting(false)
                }
                MacTextEditor(text: $prompt, isEditable: generator.status != .generating)
                    .padding(.horizontal, Theme.space4 - 4)
                    .padding(.vertical, Theme.space3 - 6)
            }
            .frame(height: 120)
            .themeInputField()
        }
    }

    // MARK: - Speaker count (Multi-Talk only)

    private var speakerCountPicker: some View {
        HStack(spacing: Theme.space3) {
            Text("Speakers")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Picker("", selection: $speakerCount) {
                ForEach(2...6, id: \.self) { n in
                    Text("\(n)").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .disabled(generator.status == .generating)
            Spacer()
        }
    }

    // MARK: - System prompt

    private var systemPromptSection: some View {
        // Picker over the SwiftData-backed prompt presets for this
        // scope; opens the PromptManagerSheet for full CRUD. Active
        // selection is what gets passed to the generator below.
        ActivePromptPicker(scope: promptScope, showsManager: $showsPromptManager)
    }

    // MARK: - Generate button

    private var generateButton: some View {
        Button(action: {
            generator.generate(
                prompt: prompt,
                mode: mode,
                speakerCount: speakerCount,
                settings: chatSettings,
                baseURL: currentEndpointBaseURL(),
                systemPromptContent: activePromptContent()
            )
        }) {
            HStack(spacing: Theme.space2) {
                if generator.status == .generating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Generating…")
                } else {
                    Image(systemName: "sparkles")
                    Text("Generate")
                }
            }
            .font(Theme.fontSMBold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.space3)
            .background(canGenerate ? Theme.accent : Color.gray.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .disabled(!canGenerate)
    }

    // MARK: - Preview

    private var previewArea: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Preview")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)

            ScrollView {
                Text(generator.preview)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.space3)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .themeInputField()
        }
    }

    // MARK: - Error

    private func errorLabel(_ msg: String) -> some View {
        Text(msg)
            .font(Theme.fontXS)
            .foregroundStyle(Theme.errorFG)
    }

    // MARK: - Accept row

    private var acceptRow: some View {
        HStack {
            Spacer()
            Button("Use Script") {
                let script = generator.preview.trimmingCharacters(in: .whitespacesAndNewlines)
                let names = mode == .multiTalk ? generator.extractedSpeakerNames : []
                onAccept(script, names)
                isPresented = false
            }
            .buttonStyle(.plain)
            .font(Theme.fontSMBold)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, Theme.space3)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    // MARK: - Helpers

    private var canGenerate: Bool {
        guard case .connected = generator.connectionState else { return false }
        guard generator.status != .generating else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func dismiss() {
        generator.cancel()
        // chatSettings is no longer the system-prompt store — saves
        // happen on every keystroke via SwiftData autosave from the
        // PromptManagerSheet. Still persist the rest of chatSettings
        // (model name, voice selections) in case anything changed
        // through other binds during this modal's lifetime.
        SettingsStore.save(chatSettings)
        isPresented = false
    }
}
