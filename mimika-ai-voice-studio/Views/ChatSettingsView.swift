//
//  ChatSettingsView.swift
//  mimika-ai-voice-studio
//
//  Chat-scoped settings: the TTS voice used for spoken chat replies, and
//  the chat system prompt sent on every conversation. App-wide settings
//  (LLM endpoint config, Pocket-TTS tuning) live in AppSettingsView and are
//  reachable from a gear icon in the global header — not from this sheet,
//  which is only triggered by the Chat tab's own gear button because
//  these fields don't apply outside the Chat context.

import SwiftData
import SwiftUI

struct ChatSettingsView: View {
    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    let voices: [BundledVoice]
    let onSave: (ChatSettings) -> Void

    @State private var workingCopy: ChatSettings
    @State private var showsPromptManager = false

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        voices: [BundledVoice],
        onSave: @escaping (ChatSettings) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self.voices = voices
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
    }

    var body: some View {
        ModalContainer(title: "Chat Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                voiceSection
                Divider().background(Theme.borderColor)
                systemPromptSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
        .sheet(isPresented: $showsPromptManager) {
            PromptManagerSheet(isPresented: $showsPromptManager, scope: .chat)
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        let importedVoices = VoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }
        let builtInVoices = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: Theme.space3) {
            Text("TTS Voice for chat replies")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $workingCopy.ttsVoiceID) {
                VoicePickerFallback.unavailableTag(
                    selection: workingCopy.ttsVoiceID,
                    isKnown: builtInVoices.contains { $0.id == workingCopy.ttsVoiceID }
                        || importedVoices.contains { "imported:\($0.id)" == workingCopy.ttsVoiceID }
                )
                Section("Built-in") {
                    ForEach(builtInVoices, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                if !importedVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(importedVoices) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name).tag("imported:\(v.id)")
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()

            // Seed affordance for the chat voice. Self-hides for stock voices.
            if workingCopy.ttsVoiceID.hasPrefix("imported:") {
                HStack(spacing: Theme.space2) {
                    Text("Seed")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    SeedControl(voiceID: workingCopy.ttsVoiceID, style: .card)
                    Spacer()
                }
            }
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("System Prompt")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Sent as the first system message in every conversation. Pick from saved prompts or open the editor to rename / add / duplicate.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ActivePromptPicker(scope: .chat, showsManager: $showsPromptManager)
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
            .accessibilityIdentifier("chatSettings.doneButton")
        }
    }

    // MARK: - Actions

    private func cancel() {
        isPresented = false
    }

    private func saveAndClose() {
        settings = workingCopy
        onSave(workingCopy)
        isPresented = false
    }
}
