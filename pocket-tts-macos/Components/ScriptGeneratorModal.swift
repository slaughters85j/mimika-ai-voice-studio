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

import SwiftUI

struct ScriptGeneratorModal: View {
    @Binding var isPresented: Bool
    let mode: ScriptGeneratorMode
    @Binding var chatSettings: ChatSettings
    let onAccept: (_ script: String, _ speakerNames: [String]) -> Void

    @State private var generator = ScriptGenerator()
    @State private var prompt: String = ""
    @State private var speakerCount: Int = 2
    @State private var showSystemPrompt = false

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
        .task { await generator.checkConnection(settings: chatSettings) }
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

            TextField("e.g. A woman talking about planting flowers…", text: $prompt, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space4)
                .padding(.vertical, Theme.space3)
                .themeInputField()
                .disabled(generator.status == .generating)
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
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showSystemPrompt.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showSystemPrompt ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                        Text("System Prompt")
                            .font(Theme.fontXS)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if showSystemPrompt && currentPrompt != defaultPrompt {
                    Button("Reset") {
                        setCurrentPrompt(defaultPrompt)
                    }
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }

            if showSystemPrompt {
                TextEditor(text: systemPromptBinding)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.space3)
                    .frame(minHeight: 80, maxHeight: 140)
                    .themeInputField()
            }
        }
    }

    // MARK: - Generate button

    private var generateButton: some View {
        Button(action: {
            generator.generate(
                prompt: prompt,
                mode: mode,
                speakerCount: speakerCount,
                settings: chatSettings
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
        SettingsStore.save(chatSettings)
        isPresented = false
    }

    private var currentPrompt: String {
        mode == .singleVoice ? chatSettings.singleVoiceSystemPrompt : chatSettings.multiTalkSystemPrompt
    }

    private var defaultPrompt: String {
        mode == .singleVoice ? ChatSettings.defaultSingleVoicePrompt : ChatSettings.defaultMultiTalkPrompt
    }

    private func setCurrentPrompt(_ value: String) {
        if mode == .singleVoice {
            chatSettings.singleVoiceSystemPrompt = value
        } else {
            chatSettings.multiTalkSystemPrompt = value
        }
    }

    private var systemPromptBinding: Binding<String> {
        mode == .singleVoice
            ? $chatSettings.singleVoiceSystemPrompt
            : $chatSettings.multiTalkSystemPrompt
    }
}
